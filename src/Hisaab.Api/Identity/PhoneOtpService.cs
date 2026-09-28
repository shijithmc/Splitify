using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Identity;

public sealed record PhoneChallengeRequest(string PhoneNumber);
public sealed record PhoneReauthenticationRequest(string Nonce, string Code);
public sealed record PhoneChallengeResult(string Nonce, DateTimeOffset ExpiresAt, int ResendAfterSeconds);
public sealed record PhoneChallengeRecord(DateTimeOffset ExpiresAt, string EncryptedPhoneNumber, string VerificationSid, string Purpose, string? UserId, DateTimeOffset? AuthenticatedAt, int Attempts = 0);
public sealed record PhoneSendRecord(DateTimeOffset RetryAt);
public sealed record PhoneVerification(VerifiedIdentity Identity, StoreRow Challenge);

public sealed partial class PhoneOtpService(IAtomicStore store, IPhoneOtpProvider provider, TokenProtector protector,
    DistributedRateLimiter limiter, IConfiguration configuration, TimeProvider clock)
{
    public async Task<PhoneChallengeResult> ChallengeAsync(string input, string sourceIp, string purpose = "sign-in", Actor? actor = null, CancellationToken ct = default)
    {
        var phone = (input ?? "").Trim();
        if (!PhoneNumber().IsMatch(phone)) throw new DomainException(422, "phone_invalid", "Enter a phone number with country code, such as +919876543210.");
        provider.EnsureConfigured();
        var subject = Subject(phone);
        // Check encryption before making a billable request.
        var encrypted = protector.Protect(phone);
        if (purpose == "link") IdentityService.Recent(actor!);
        if (purpose == "reauthenticate")
        {
            var owner = await store.GetAsync(IdentityService.IdentityKey("phone", subject), "OWNER", ct);
            if (owner?.Deserialize<ProviderIdentity>().UserId != actor!.User.Id) throw new DomainException(422, "phone_not_linked", "Use the phone number linked to this account.");
        }
        var now = clock.GetUtcNow();
        var sendKey = $"PHONE_SEND#{subject}";
        var send = await store.GetAsync(sendKey, "META", ct);
        if (send is not null && send.Deserialize<PhoneSendRecord>().RetryAt > now) throw RateLimited((int)Math.Ceiling((send.Deserialize<PhoneSendRecord>().RetryAt - now).TotalSeconds));
        // Reserve the cooldown first: concurrent instances must not both send an SMS.
        try { await store.TransactAsync([StoreMutation.Put(StoreRow.Create(sendKey, "META", (send?.Version ?? 0) + 1, new PhoneSendRecord(now.AddSeconds(60)), now.AddMinutes(2).ToUnixTimeSeconds()), send?.Version)], ct); }
        catch (StoreConflictException) { throw RateLimited(); }
        var allowance = await limiter.AdmitAsync([
            new("phone-send-ip", sourceIp, 5, 600), new("phone-send-ip-day", sourceIp, 20, 86400),
            new("phone-send-number-hour", subject, 3, 3600), new("phone-send-number-day", subject, 5, 86400),
            new("phone-send-global-minute", "sms", Limit("MaxSmsPerMinute", 10), 60),
            new("phone-send-global-day", "sms", Limit("MaxSmsPerDay", 100), 86400)
        ], ct);
        if (!allowance.Allowed) throw RateLimited(allowance.RetryAfterSeconds);
        var verification = await provider.SendAsync(phone, ct);
        var nonce = Ids.Token(); var until = now.AddMinutes(10);
        var challenge = new PhoneChallengeRecord(until, encrypted, verification, purpose, actor?.User.Id, actor?.AuthenticatedAt);
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create($"CHALLENGE#{Ids.Hash(nonce)}", "META", 1, challenge, until.ToUnixTimeSeconds()), null)], ct);
        return new(nonce, until, 60);
    }

    public async Task<PhoneVerification> VerifyAsync(StoreRow row, string code, string purpose, Actor? actor, CancellationToken ct)
    {
        provider.EnsureConfigured();
        if (!IsPhoneChallenge(row)) throw Invalid();
        var challenge = row.Deserialize<PhoneChallengeRecord>();
        if (challenge.ExpiresAt <= clock.GetUtcNow() || challenge.Purpose != purpose || challenge.UserId != actor?.User.Id ||
            challenge.AuthenticatedAt != actor?.AuthenticatedAt || challenge.Attempts >= 5) throw Invalid();
        if (string.IsNullOrEmpty(code) || !Code().IsMatch(code)) throw new DomainException(422, "phone_code_invalid", "Enter the six-digit SMS code.");
        var phone = protector.Unprotect(challenge.EncryptedPhoneNumber);
        var subject = Subject(phone);
        var allowance = await limiter.AdmitAsync([new("phone-check-number", subject, 10, 600)], ct);
        if (!allowance.Allowed) throw RateLimited(allowance.RetryAfterSeconds);
        var next = StoreRow.Create(row.Pk, row.Sk, row.Version + 1, challenge with { Attempts = challenge.Attempts + 1 }, challenge.ExpiresAt.ToUnixTimeSeconds());
        try { await store.TransactAsync([StoreMutation.Put(next, row.Version)], ct); }
        catch (StoreConflictException) { throw Invalid(); }
        if (!await provider.CheckAsync(challenge.VerificationSid, phone, code, ct)) throw Invalid();
        return new(new("phone", subject, null, false, "twilio-verify"), next);
    }

    public static bool IsPhoneChallenge(StoreRow row) => row.Data.TryGetProperty("encryptedPhoneNumber", out _);
    private string Subject(string phone)
    {
        var key = configuration["Hisaab:ContactHashKey"];
        if (string.IsNullOrWhiteSpace(key)) throw new DomainException(503, "phone_unavailable", "Phone sign-in is not available yet. Try another sign-in method.");
        return Convert.ToHexString(HMACSHA256.HashData(Encoding.UTF8.GetBytes(key), Encoding.UTF8.GetBytes("phone:" + phone))).ToLowerInvariant();
    }
    private int Limit(string key, int fallback)
    {
        var configured = configuration[$"Hisaab:Auth:Phone:{key}"];
        if (configured is null) return fallback;
        if (int.TryParse(configured, out var limit) && limit is >= 1 and <= 10000) return limit;
        throw new DomainException(503, "phone_unavailable", "Phone sign-in is not available yet. Try another sign-in method.");
    }
    private static DomainException Invalid() => new(401, "phone_code_invalid", "The code is invalid or expired. Check it or request a new code.");
    private static DomainException RateLimited(int retryAfterSeconds = 60) => new(429, "phone_rate_limited", "Too many SMS attempts. Wait before requesting or checking another code.", retryAfterSeconds);
    [GeneratedRegex(@"\A\+[1-9][0-9]{7,14}\z")] private static partial Regex PhoneNumber();
    [GeneratedRegex(@"\A[0-9]{6}\z")] private static partial Regex Code();
}
