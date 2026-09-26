using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using Hisaab.Api.Receipts;
using Hisaab.Api.Receipts.Infrastructure;
using Hisaab.Api.Shared;
using Hisaab.Domain.Receipts;
using Hisaab.ReceiptEval;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

if (args.Length != 3 || args[0] is not ("validate" or "run"))
{
    Console.Error.WriteLine("Usage: Hisaab.ReceiptEval validate MANIFEST REPORT | run MANIFEST REPORT. Running additionally requires HISAAB_EVAL_SEND_TO_PROVIDER=yes and validated provider environment configuration.");
    return 2;
}
var manifestPath = Path.GetFullPath(args[1]);
var cases = JsonSerializer.Deserialize<EvaluationCase[]>(await File.ReadAllTextAsync(manifestPath), JsonDefaults.Options) ?? [];
var categories = new[] { "restaurant", "grocery", "fuel", "pharmacy", "handwritten" };
if (cases.Length > 2000 || cases.Count(c => c.Classification == "bill") < 200 || cases.Any(c => !c.ContributorPermission || c.Classification is not ("bill" or "not_bill") || c.Images.Length is < 1 or > 3 || string.IsNullOrWhiteSpace(c.Id)) ||
    cases.Select(c => c.Id).Distinct().Count() != cases.Length || cases.Where(c => c.Classification == "bill").Select(c => c.Script).Distinct().Count() < 5 ||
    categories.Any(category => !cases.Any(c => c.Category == category && c.Classification == "bill")) || !cases.Any(c => c.Classification == "not_bill") ||
    cases.Any(c => c.Classification == "bill" && (c.Expected is null || c.Expected.SourceCurrency != "INR" || c.Expected.GrandTotalPaise <= 0)))
{
    Console.Error.WriteLine("Invalid corpus: require 200+ labelled INR bills, five scripts, all five categories, negative examples, unique IDs, explicit contributor permission and 1–3 normalized images per case.");
    return 2;
}
var sourceDirectory = Path.GetDirectoryName(manifestPath)!;
// Validate every source before sending anything. This is an explicit local operator corpus, never production export.
foreach (var sample in cases)
foreach (var image in sample.Images)
{
    var info = new FileInfo(Path.GetFullPath(image, sourceDirectory));
    if (!info.Exists || info.Length is <= 0 or > ReceiptImageNormalizer.MaxBytes) { Console.Error.WriteLine("Missing or oversized corpus image."); return 2; }
    try
    {
        var bytes = await File.ReadAllBytesAsync(info.FullName);
        var mime = bytes.Length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 ? "image/png" : "image/jpeg";
        ReceiptImageNormalizer.Normalize(bytes, new ReceiptUploadSlot(Guid.NewGuid().ToString(), "", mime, bytes.Length, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()));
    }
    catch (Hisaab.Domain.DomainException) { Console.Error.WriteLine("Invalid corpus image: use upright normalized JPEG/PNG, at most 2048 pixels per side."); return 2; }
}
if (args[0] == "validate")
{
    await File.WriteAllTextAsync(args[2], JsonSerializer.Serialize(new { validManifest = true, billCount = cases.Count(c => c.Classification == "bill"), evaluationsPerformed = 0 }, JsonDefaults.Options));
    return 0;
}
if (Environment.GetEnvironmentVariable("HISAAB_EVAL_SEND_TO_PROVIDER") != "yes") { Console.Error.WriteLine("No provider calls made. Set HISAAB_EVAL_SEND_TO_PROVIDER=yes only for an authorized protected corpus."); return 2; }
var configuration = new ConfigurationManager(); configuration.AddEnvironmentVariables();
var temporary = Path.Combine(Path.GetTempPath(), "hisaab-evaluation-" + Guid.NewGuid().ToString("N"));
configuration["Hisaab:Receipts:LocalPath"] = temporary;
configuration["Hisaab:EncryptionKey"] = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
var services = new ServiceCollection(); services.AddHttpClient("receipt-vertex", client => client.Timeout = TimeSpan.FromSeconds(21));
using var container = services.BuildServiceProvider();
var blobs = new LocalReceiptBlobStore(configuration);
var extractor = new VertexReceiptExtractor(blobs, new WorkloadIdentityToken(configuration), container.GetRequiredService<IHttpClientFactory>(), configuration);
var results = new List<EvaluationResult>();
try
{
    foreach (var sample in cases)
    {
        var receiptId = Guid.NewGuid().ToString(); var uploads = new List<ReceiptUploadSlot>();
        try
        {
            foreach (var path in sample.Images)
            {
                var bytes = await File.ReadAllBytesAsync(Path.GetFullPath(path, sourceDirectory));
                var imageId = Guid.NewGuid().ToString(); var mime = bytes.Length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 ? "image/png" : "image/jpeg";
                var slot = new ReceiptUploadSlot(imageId, $"quarantine/{receiptId}/{imageId}", mime, bytes.Length, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
                await blobs.AcceptUploadAsync(slot, new MemoryStream(bytes)); uploads.Add(slot);
            }
            var media = await blobs.ValidateAsync(receiptId, uploads);
            var timer = Stopwatch.StartNew(); ReceiptExtraction? extraction = null; var error = false;
            try { extraction = await extractor.ExtractAsync(media); }
            catch (ReceiptProviderException) { error = true; }
            timer.Stop();
            var review = extraction?.Document?.Deserialize<ReceiptReview>(JsonDefaults.Options);
            var read = extraction?.Classification == "bill" && review is not null;
            var expected = sample.Expected;
            var totalTaxExact = read && expected is not null && review!.SourceCurrency == "INR" && review.GrandTotalPaise == expected.GrandTotalPaise &&
                Taxes(review).SequenceEqual(Taxes(expected));
            var itemsExact = read && expected is not null && Items(review!).SequenceEqual(Items(expected));
            results.Add(new(sample.Category, sample.Script, sample.Classification == "bill", read, totalTaxExact, itemsExact, sample.Classification == "not_bill" && read,
                timer.ElapsedMilliseconds, extraction?.Usage?.InputTokens, extraction?.Usage?.OutputTokens, extraction?.Usage?.ThinkingTokens, error));
            Console.WriteLine($"Completed {results.Count}/{cases.Length}; no receipt content retained in report.");
        }
        finally { await blobs.DeleteAsync(receiptId); }
    }
    var summary = EvaluationSummary.From(results);
    var report = new
    {
        model = configuration["Hisaab:Receipts:VertexModel"] ?? "gemini-3.5-flash", prompt = ReceiptExtractionSchema.PromptVersion, schema = ReceiptExtractionSchema.Version,
        createdAt = DateTimeOffset.UtcNow, summary,
        latencyScope = "normalized local media read, federation, provider inference and strict parsing; excludes network upload, queue delay and mobile rendering",
        byScript = results.GroupBy(r => r.Script).ToDictionary(g => g.Key, g => EvaluationSummary.From(g.ToArray())),
        byCategory = results.GroupBy(r => r.Category).ToDictionary(g => g.Key, g => EvaluationSummary.From(g.ToArray())),
        accuracyTargetsMet = summary.ReadingRate >= .92m && summary.TotalAndTaxExactRate >= .85m,
        billing = "Token counts only. Reconcile all attempts including errors against the provider billing export; no actual cost or end-to-end latency claim is made."
    };
    await File.WriteAllTextAsync(args[2], JsonSerializer.Serialize(report, new JsonSerializerOptions(JsonDefaults.Options) { WriteIndented = true }));
    return summary.ReadingRate >= .92m && summary.TotalAndTaxExactRate >= .85m ? 0 : 1;
}
finally { if (Directory.Exists(temporary)) Directory.Delete(temporary, true); }

static string[] Taxes(ReceiptReview value) => value.Charges.Where(c => c.Kind == "Tax").Select(c => $"{c.Name.Normalize().Trim()}|{c.AmountPaise}|{c.IncludedInItemPrices}").Order(StringComparer.Ordinal).ToArray();
static string[] Items(ReceiptReview value) => value.Items.Select(i => $"{i.Name.Normalize().Trim()}|{i.Quantity}|{i.UnitPricePaise}|{i.LineTotalPaise}").Order(StringComparer.Ordinal).ToArray();
