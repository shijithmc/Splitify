using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Hisaab.Domain;
namespace Hisaab.Api.Identity;

public interface IPhoneOtpProvider
{
    void EnsureConfigured();
    Task<string> SendAsync(string phoneNumber, CancellationToken ct);
    Task<bool> CheckAsync(string verificationSid, string phoneNumber, string code, CancellationToken ct);
}

/// <summary>Twilio owns code generation and delivery. No local or development OTP bypass.</summary>
public sealed partial class PhoneOtpProvider(IConfiguration configuration, IHttpClientFactory clients) : IPhoneOtpProvider
{
    private const string Prefix = "Hisaab:Auth:Phone:";
    public void EnsureConfigured()
    {
        if (!configuration.GetValue<bool>(Prefix + "Enabled") ||
            !ServiceSid().IsMatch(configuration[Prefix + "ServiceSid"] ?? "") ||
            !ApiKeySid().IsMatch(configuration[Prefix + "ApiKeySid"] ?? "") ||
            string.IsNullOrWhiteSpace(configuration[Prefix + "ApiKeySecret"]))
            throw new DomainException(503, "phone_unavailable", "Phone sign-in is not available yet. Try another sign-in method.");
    }

    public async Task<string> SendAsync(string phoneNumber, CancellationToken ct)
    {
        using var response = await PostAsync("Verifications", new() { ["To"] = phoneNumber, ["Channel"] = "sms" }, ct);
        if (response.StatusCode == HttpStatusCode.TooManyRequests) throw RateLimited();
        if (!response.IsSuccessStatusCode) throw Unavailable();
        var data = await ReadAsync(response, ct);
        var sid = Value(data, "sid");
        if (!VerificationSid().IsMatch(sid) || Value(data, "status") != "pending" ||
            Value(data, "to") != phoneNumber || Value(data, "channel") != "sms" ||
            Value(data, "service_sid") != configuration[Prefix + "ServiceSid"]) throw Unavailable();
        return sid;
    }

    public async Task<bool> CheckAsync(string verificationSid, string phoneNumber, string code, CancellationToken ct)
    {
        using var response = await PostAsync("VerificationCheck", new() { ["VerificationSid"] = verificationSid, ["Code"] = code }, ct);
        if (response.StatusCode == HttpStatusCode.NotFound || response.StatusCode == HttpStatusCode.BadRequest) return false;
        if (response.StatusCode == HttpStatusCode.TooManyRequests) throw RateLimited();
        if (!response.IsSuccessStatusCode) throw Unavailable();
        var data = await ReadAsync(response, ct);
        return Value(data, "status") == "approved" && Value(data, "sid") == verificationSid &&
            Value(data, "to") == phoneNumber && Value(data, "channel") == "sms" &&
            Value(data, "service_sid") == configuration[Prefix + "ServiceSid"];
    }

    private async Task<HttpResponseMessage> PostAsync(string resource, Dictionary<string, string> fields, CancellationToken ct)
    {
        EnsureConfigured();
        using var request = new HttpRequestMessage(HttpMethod.Post, $"https://verify.twilio.com/v2/Services/{configuration[Prefix + "ServiceSid"]}/{resource}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{configuration[Prefix + "ApiKeySid"]}:{configuration[Prefix + "ApiKeySecret"]}")));
        request.Content = new FormUrlEncodedContent(fields);
        try { return await clients.CreateClient("phone-otp").SendAsync(request, ct); }
        catch (HttpRequestException) { throw Unavailable(); }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw Unavailable(); }
    }

    private static async Task<JsonElement> ReadAsync(HttpResponseMessage response, CancellationToken ct)
    {
        try { using var document = await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync(ct), cancellationToken: ct); return document.RootElement.Clone(); }
        catch (JsonException) { throw Unavailable(); }
    }
    private static string Value(JsonElement data, string key) => data.ValueKind == JsonValueKind.Object && data.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : "";
    private static DomainException Unavailable() => new(503, "phone_unavailable", "The SMS service is unavailable. Please try again later.");
    private static DomainException RateLimited() => new(429, "phone_rate_limited", "Too many SMS attempts. Please try again later.");
    [GeneratedRegex(@"\AVA[0-9a-fA-F]{32}\z")] private static partial Regex ServiceSid();
    [GeneratedRegex(@"\ASK[0-9a-fA-F]{32}\z")] private static partial Regex ApiKeySid();
    [GeneratedRegex(@"\AVE[0-9a-fA-F]{32}\z")] private static partial Regex VerificationSid();
}
