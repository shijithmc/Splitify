using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Hisaab.Api.Shared;
using Hisaab.Domain;
namespace Hisaab.Api.Identity;

public sealed class ProviderVerifier(IConfiguration config) : IProviderVerifier
{
    private readonly Dictionary<string, ConfigurationManager<OpenIdConnectConfiguration>> managers = new()
    {
        ["google"] = new("https://accounts.google.com/.well-known/openid-configuration", new OpenIdConnectConfigurationRetriever()),
        ["apple"] = new("https://appleid.apple.com/.well-known/openid-configuration", new OpenIdConnectConfigurationRetriever())
    };
    public async Task<VerifiedIdentity> VerifyAsync(SignInRequest request, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(request.Provider) || !managers.TryGetValue(request.Provider, out var manager)) throw new DomainException(400, "provider_invalid", "Choose Apple or Google.");
        var audiences = (config[$"Hisaab:Auth:{request.Provider}:ClientIds"] ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (audiences.Length == 0) throw new DomainException(503, "provider_unconfigured", "This sign-in provider is not configured yet.");
        if (string.IsNullOrWhiteSpace(request.IdToken) || request.IdToken.Length > 16000) throw new DomainException(401, "identity_invalid", "Sign in again.");
        var handler = new JwtSecurityTokenHandler { MapInboundClaims = false };
        try
        {
            var oidc = await manager.GetConfigurationAsync(ct);
            var parameters = new TokenValidationParameters
            {
                ValidateIssuerSigningKey = true,
                IssuerSigningKeys = oidc.SigningKeys,
                ValidateIssuer = true,
                ValidIssuers = request.Provider == "google" ? ["https://accounts.google.com", "accounts.google.com"] : ["https://appleid.apple.com"],
                ValidateAudience = true,
                ValidAudiences = audiences,
                ValidateLifetime = true,
                RequireExpirationTime = true,
                RequireSignedTokens = true,
                ValidAlgorithms = [SecurityAlgorithms.RsaSha256],
                ClockSkew = TimeSpan.FromSeconds(30)
            };
            ClaimsPrincipal principal;
            SecurityToken validated;
            try { principal = handler.ValidateToken(request.IdToken, parameters, out validated); }
            catch (SecurityTokenSignatureKeyNotFoundException) { manager.RequestRefresh(); oidc = await manager.GetConfigurationAsync(ct); parameters.IssuerSigningKeys = oidc.SigningKeys; principal = handler.ValidateToken(request.IdToken, parameters, out validated); }
            var subject = principal.FindFirstValue("sub");
            var nonce = principal.FindFirstValue("nonce");
            if (string.IsNullOrWhiteSpace(subject) || subject.Length > 255 || (request.Provider == "apple" && nonce is null) || (nonce is not null && !Ids.FixedEquals(nonce, Ids.Hash(request.Nonce)))) throw new SecurityTokenValidationException();
            var email = principal.FindFirstValue("email");
            var verified = string.Equals(principal.FindFirstValue("email_verified"), "true", StringComparison.OrdinalIgnoreCase);
            var authoritative = verified && (request.Provider == "apple" || email?.EndsWith("@gmail.com", StringComparison.OrdinalIgnoreCase) == true || principal.HasClaim(c => c.Type == "hd"));
            var jwt = (JwtSecurityToken)validated;
            return new(request.Provider, subject, verified ? email : null, authoritative, jwt.Audiences.First(a => audiences.Contains(a, StringComparer.Ordinal)));
        }
        catch (SecurityTokenException) { throw new DomainException(401, "identity_invalid", "Sign in again. The identity token could not be verified."); }
        catch (ArgumentException) { throw new DomainException(401, "identity_invalid", "Sign in again. The identity token could not be verified."); }
    }
}
