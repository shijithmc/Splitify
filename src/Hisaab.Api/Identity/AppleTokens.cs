using System.IdentityModel.Tokens.Jwt;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;
using Hisaab.Domain;
namespace Hisaab.Api.Identity;

public sealed class AppleTokens(IConfiguration config, IHttpClientFactory clients, TokenProtector protector, IProviderVerifier verifier)
{
    private string ClientSecret(string audience)
    {
        var pem = config["Hisaab:Auth:apple:PrivateKey"]; var team = config["Hisaab:Auth:apple:TeamId"]; var keyId = config["Hisaab:Auth:apple:KeyId"];
        if (string.IsNullOrWhiteSpace(pem) || string.IsNullOrWhiteSpace(team) || string.IsNullOrWhiteSpace(keyId)) throw new DomainException(503, "apple_unconfigured", "Apple token exchange is not configured.");
        // Signature providers must not cache this key beyond its per-call lifetime.
        using var ec = ECDsa.Create(); ec.ImportFromPem(pem.Replace("\\n", "\n", StringComparison.Ordinal)); var key = new ECDsaSecurityKey(ec) { KeyId = keyId, CryptoProviderFactory = new CryptoProviderFactory { CacheSignatureProviders = false } }; var now = DateTime.UtcNow;
        var jwt = new JwtSecurityToken(team, "https://appleid.apple.com", [new("sub", audience)], now, now.AddMinutes(5), new SigningCredentials(key, SecurityAlgorithms.EcdsaSha256));
        return new JwtSecurityTokenHandler().WriteToken(jwt);
    }
    public async Task<string> ExchangeAsync(string code, string audience, string expectedSubject, string nonce, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(code)) throw new DomainException(400, "apple_code_required", "Apple authorization code is required for account deletion support.");
        using var response = await clients.CreateClient().PostAsync("https://appleid.apple.com/auth/token", new FormUrlEncodedContent(new Dictionary<string, string> { { "client_id", audience }, { "client_secret", ClientSecret(audience) }, { "code", code }, { "grant_type", "authorization_code" } }), ct);
        if (!response.IsSuccessStatusCode) throw new DomainException(401, "apple_exchange_failed", "Apple sign-in could not be completed. Try again.");
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        if (!json.RootElement.TryGetProperty("id_token", out var returnedToken) || string.IsNullOrWhiteSpace(returnedToken.GetString())) throw new DomainException(401, "apple_exchange_identity_invalid", "Apple sign-in could not be bound to this account. Try again.");
        var returnedIdentity = await verifier.VerifyAsync(new SignInRequest("apple", returnedToken.GetString()!, nonce), ct);
        if (returnedIdentity.Subject != expectedSubject || returnedIdentity.Audience != audience) throw new DomainException(401, "apple_exchange_identity_invalid", "Apple sign-in could not be bound to this account. Try again.");
        if (!json.RootElement.TryGetProperty("refresh_token", out var token) || string.IsNullOrWhiteSpace(token.GetString())) throw new DomainException(502, "apple_exchange_failed", "Apple did not return revocation credentials. Try again.");
        return protector.Protect(token.GetString()!);
    }
    public async Task RevokeAsync(ProviderIdentity identity, CancellationToken ct)
    {
        if (identity.EncryptedRefreshToken is null) throw new DomainException(503, "apple_reauthentication_required", "Sign in with Apple again before deleting this account.");
        using var response = await clients.CreateClient().PostAsync("https://appleid.apple.com/auth/revoke", new FormUrlEncodedContent(new Dictionary<string, string> { { "client_id", identity.Audience }, { "client_secret", ClientSecret(identity.Audience) }, { "token", protector.Unprotect(identity.EncryptedRefreshToken) }, { "token_type_hint", "refresh_token" } }), ct);
        if (!response.IsSuccessStatusCode) throw new DomainException(503, "apple_revocation_pending", "Apple revocation is pending. Please retry account deletion.");
    }
}
