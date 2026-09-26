using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Diagnostics;

namespace Hisaab.Api.Receipts.Infrastructure;

public sealed partial class VertexReceiptExtractor(IReceiptBlobStore blobs, IVertexAccessToken tokens, IHttpClientFactory clients, IConfiguration configuration, ILogger<VertexReceiptExtractor>? logger = null) : IReceiptExtractor
{
    public async Task<ReceiptExtraction> ExtractAsync(IReadOnlyList<ReceiptMedia> media, CancellationToken ct = default)
    {
        var project = configuration["Hisaab:Receipts:VertexProject"] ?? "";
        var region = configuration["Hisaab:Receipts:VertexRegion"] ?? "asia-south1";
        var model = configuration["Hisaab:Receipts:VertexModel"] ?? "gemini-3.5-flash";
        if (!configuration.GetValue<bool>("Hisaab:Receipts:ProviderValidated") || !Project().IsMatch(project) ||
            region != "asia-south1" || !Model().IsMatch(model) || model.Contains("latest", StringComparison.Ordinal) ||
            media.Count is < 1 or > 3)
            throw new ReceiptProviderException("receipt_provider_unconfigured", false);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(20));
        var elapsed = Stopwatch.StartNew();
        var completed = false;
        ReceiptProviderUsage? usage = null;
        try
        {
            var bearer = await tokens.GetAsync(timeout.Token);
            var parts = new List<object>();
            foreach (var image in media)
            {
                if (image.SizeBytes is <= 0 or > ReceiptImageNormalizer.MaxBytes || image.ContentType != "image/jpeg")
                    throw new ReceiptProviderException("receipt_image_invalid", false);
                var bytes = await blobs.ReadAsync(image, false, 0, checked((int)image.SizeBytes), timeout.Token);
                parts.Add(new { inlineData = new { mimeType = image.ContentType, data = Convert.ToBase64String(bytes) } });
            }
            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}/publishers/google/models/{model}:generateContent");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearer);
            request.Content = JsonContent.Create(new
            {
                systemInstruction = new { parts = new[] { new { text = ReceiptExtractionSchema.Prompt } } },
                contents = new[] { new { role = "user", parts } },
                generationConfig = new { temperature = 0, candidateCount = 1, maxOutputTokens = 32768, responseMimeType = "application/json", responseSchema = ReceiptExtractionSchema.Json }
            });
            using var response = await clients.CreateClient("receipt-vertex").SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!response.IsSuccessStatusCode)
                throw new ReceiptProviderException(response.StatusCode == HttpStatusCode.TooManyRequests ? "receipt_provider_rate_limited" : "receipt_provider_unavailable",
                    response.StatusCode == HttpStatusCode.TooManyRequests || (int)response.StatusCode >= 500);
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            var bytesResponse = await S3ReceiptBlobStore.ReadBoundedAsync(stream, 1024 * 1024, timeout.Token);
            using var envelope = JsonDocument.Parse(bytesResponse, new JsonDocumentOptions { MaxDepth = 24 });
            var candidates = envelope.RootElement.GetProperty("candidates");
            if (candidates.GetArrayLength() != 1 || candidates[0].GetProperty("finishReason").GetString() != "STOP")
                throw new ReceiptProviderException("receipt_provider_incomplete", false);
            var texts = new StringBuilder();
            foreach (var part in candidates[0].GetProperty("content").GetProperty("parts").EnumerateArray())
            {
                if (part.TryGetProperty("thought", out var thought) && thought.ValueKind == JsonValueKind.True) continue;
                if (!part.TryGetProperty("text", out var text)) throw new ReceiptProviderException("receipt_provider_invalid_output", false);
                texts.Append(text.GetString());
            }
            if (envelope.RootElement.TryGetProperty("usageMetadata", out var metadata))
                usage = new(Count(metadata, "promptTokenCount"), Count(metadata, "candidatesTokenCount"), Count(metadata, "thoughtsTokenCount"));
            var result = ReceiptExtractionParser.Parse(texts.ToString(), model) with { Usage = usage };
            completed = true;
            return result;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new ReceiptProviderException("receipt_provider_timeout", true); }
        catch (HttpRequestException) { throw new ReceiptProviderException("receipt_provider_unavailable", true); }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        { throw new ReceiptProviderException("receipt_provider_invalid_output", false); }
        finally
        {
            // Aggregate diagnostics only. No model text, merchant, account/receipt ID or image data.
            logger?.LogInformation("Receipt provider attempt: {ElapsedMs}ms, completed={Completed}, inputTokens={InputTokens}, outputTokens={OutputTokens}, thinkingTokens={ThinkingTokens}",
                elapsed.ElapsedMilliseconds, completed, usage?.InputTokens, usage?.OutputTokens, usage?.ThinkingTokens);
        }
    }
    private static long Count(JsonElement metadata, string name) => metadata.TryGetProperty(name, out var value) && value.TryGetInt64(out var number) && number >= 0 ? number : 0;
    [GeneratedRegex("^[a-z][a-z0-9-]{4,61}[a-z0-9]$|^[0-9]{6,20}$", RegexOptions.CultureInvariant)] private static partial Regex Project();
    [GeneratedRegex("^gemini-[a-z0-9.-]{3,80}$", RegexOptions.CultureInvariant)] private static partial Regex Model();
}
