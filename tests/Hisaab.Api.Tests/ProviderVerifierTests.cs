using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Domain;
using Microsoft.Extensions.Configuration;
using Microsoft.IdentityModel.Tokens;

namespace Hisaab.Api.Tests;

public sealed class ProviderVerifierTests
{
    [Theory]
    [InlineData("google")]
    [InlineData("apple")]
    public async Task SignedTokenIsVerifiedUsingDiscoveredPublicJwks(string provider)
    {
        using var fixture = new ProviderFixture();
        var identity = await fixture.Verifier.VerifyAsync(fixture.Request(provider));
        Assert.Equal(provider, identity.Provider);
        Assert.Equal("provider-subject", identity.Subject);
        Assert.Equal("member@gmail.com", identity.Email);
        Assert.True(identity.AuthoritativeEmail);
        Assert.Equal(ProviderFixture.Audience(provider), identity.Audience);
        Assert.Contains($"{ProviderFixture.Issuer(provider)}/.well-known/openid-configuration", fixture.RequestedUris);
        Assert.Contains($"{ProviderFixture.Issuer(provider)}/test-jwks", fixture.RequestedUris);
    }

    [Theory]
    [InlineData("google", "issuer")]
    [InlineData("apple", "issuer")]
    [InlineData("google", "audience")]
    [InlineData("apple", "audience")]
    [InlineData("google", "audience-trailing-slash")]
    [InlineData("apple", "audience-trailing-slash")]
    [InlineData("google", "expired")]
    [InlineData("apple", "expired")]
    [InlineData("google", "expiration-missing")]
    [InlineData("apple", "expiration-missing")]
    [InlineData("google", "not-yet-valid")]
    [InlineData("apple", "not-yet-valid")]
    [InlineData("google", "subject-missing")]
    [InlineData("apple", "subject-missing")]
    [InlineData("google", "nonce-mismatch")]
    [InlineData("apple", "nonce-mismatch")]
    [InlineData("google", "nonce-unhashed")]
    [InlineData("apple", "nonce-unhashed")]
    public async Task SignedButInvalidClaimsAreRejected(string provider, string invalidClaim)
    {
        using var fixture = new ProviderFixture();
        var token = fixture.Token(provider, payload =>
        {
            switch (invalidClaim)
            {
                case "issuer": payload["iss"] = "https://attacker.example"; break;
                case "audience": payload["aud"] = "another-app"; break;
                case "audience-trailing-slash": payload["aud"] = ProviderFixture.Audience(provider) + "/"; break;
                case "expired": payload["exp"] = DateTimeOffset.UtcNow.AddMinutes(-2).ToUnixTimeSeconds(); break;
                case "expiration-missing": payload.Remove("exp"); break;
                case "not-yet-valid": payload["nbf"] = DateTimeOffset.UtcNow.AddMinutes(2).ToUnixTimeSeconds(); break;
                case "subject-missing": payload.Remove("sub"); break;
                case "nonce-mismatch": payload["nonce"] = Ids.Hash("another-challenge"); break;
                case "nonce-unhashed": payload["nonce"] = ProviderFixture.Nonce; break;
            }
        });
        await AssertIdentityInvalid(fixture.Verifier, fixture.Request(provider, token));
    }

    [Theory]
    [InlineData("google")]
    [InlineData("apple")]
    public async Task ForgedSignatureCannotUseTrustedKeyIdentifier(string provider)
    {
        using var fixture = new ProviderFixture();
        using var attacker = RSA.Create(2048);
        var forgedKey = new RsaSecurityKey(attacker) { KeyId = "provider-key" };
        var token = fixture.Token(provider, credentials: new SigningCredentials(forgedKey, SecurityAlgorithms.RsaSha256));
        await AssertIdentityInvalid(fixture.Verifier, fixture.Request(provider, token));
    }

    [Theory]
    [InlineData("google", SecurityAlgorithms.RsaSha384)]
    [InlineData("apple", SecurityAlgorithms.RsaSha384)]
    [InlineData("google", "none")]
    [InlineData("apple", "none")]
    public async Task UnsignedAndNonRs256TokensAreRejected(string provider, string algorithm)
    {
        using var fixture = new ProviderFixture();
        var token = fixture.Token(provider, algorithm: algorithm);
        await AssertIdentityInvalid(fixture.Verifier, fixture.Request(provider, token));
    }

    [Fact]
    public async Task AppleRequiresNonceWhileNativeGoogleCanOmitIt()
    {
        using var fixture = new ProviderFixture();
        var apple = fixture.Token("apple", payload => payload.Remove("nonce"));
        await AssertIdentityInvalid(fixture.Verifier, fixture.Request("apple", apple));
        // Google native SDK does not support a fresh per-authentication nonce.
        var google = fixture.Token("google", payload => payload.Remove("nonce"));
        Assert.Equal("provider-subject", (await fixture.Verifier.VerifyAsync(fixture.Request("google", google))).Subject);
    }

    [Fact]
    public async Task GoogleAcceptsDocumentedIssuerWithoutScheme()
    {
        using var fixture = new ProviderFixture();
        var token = fixture.Token("google", payload => payload["iss"] = "accounts.google.com");
        Assert.Equal("provider-subject", (await fixture.Verifier.VerifyAsync(fixture.Request("google", token))).Subject);
    }

    [Theory]
    [InlineData("google", "member@gmail.com", true, null, true)]
    [InlineData("google", "member@workspace.example", true, "workspace.example", true)]
    [InlineData("google", "member@external.example", true, null, false)]
    [InlineData("google", "member@gmail.com", false, null, false)]
    [InlineData("apple", "member@privaterelay.appleid.com", true, null, true)]
    [InlineData("apple", "member@privaterelay.appleid.com", false, null, false)]
    public async Task EmailAuthorityRequiresVerifiedProviderOwnership(string provider, string email, bool verified, string? hostedDomain, bool authoritative)
    {
        using var fixture = new ProviderFixture();
        var token = fixture.Token(provider, payload =>
        {
            payload["email"] = email;
            payload["email_verified"] = verified;
            if (hostedDomain is not null) payload["hd"] = hostedDomain;
        });
        var identity = await fixture.Verifier.VerifyAsync(fixture.Request(provider, token));
        Assert.Equal(verified ? email : null, identity.Email);
        Assert.Equal(authoritative, identity.AuthoritativeEmail);
    }

    private static async Task AssertIdentityInvalid(ProviderVerifier verifier, SignInRequest request)
    {
        var error = await Assert.ThrowsAsync<DomainException>(() => verifier.VerifyAsync(request));
        Assert.Equal(401, error.Status);
        Assert.Equal("identity_invalid", error.Code);
    }

    private sealed class ProviderFixture : IDisposable
    {
        public const string Nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        private readonly RSA signingKey = RSA.Create(2048);
        private readonly TestHttpClientFactory clients;
        private readonly RsaSecurityKey key;
        public List<string> RequestedUris { get; } = [];
        public ProviderVerifier Verifier { get; }
        public static string Issuer(string provider) => provider == "google" ? "https://accounts.google.com" : "https://appleid.apple.com";
        public static string Audience(string provider) => provider == "google" ? "hisaab-web.apps.googleusercontent.com" : "app.hisaab.hisaab";

        public ProviderFixture()
        {
            key = new RsaSecurityKey(signingKey) { KeyId = "provider-key", CryptoProviderFactory = new CryptoProviderFactory { CacheSignatureProviders = false } };
            var publicKey = signingKey.ExportParameters(false);
            clients = new TestHttpClientFactory(request =>
            {
                var uri = request.RequestUri!;
                RequestedUris.Add(uri.AbsoluteUri);
                Assert.Equal("https", uri.Scheme);
                Assert.Contains(uri.Host, new[] { "accounts.google.com", "appleid.apple.com" });
                if (uri.AbsolutePath == "/.well-known/openid-configuration")
                    return new HttpResponseMessage(HttpStatusCode.OK) { Content = JsonContent.Create(new { issuer = $"https://{uri.Host}", jwks_uri = $"https://{uri.Host}/test-jwks" }) };
                Assert.Equal("/test-jwks", uri.AbsolutePath);
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new { keys = new[] { new { kty = "RSA", kid = key.KeyId, use = "sig", alg = "RS256", n = Base64UrlEncoder.Encode(publicKey.Modulus!), e = Base64UrlEncoder.Encode(publicKey.Exponent!) } } })
                };
            });
            var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Hisaab:Auth:google:ClientIds"] = Audience("google"),
                ["Hisaab:Auth:apple:ClientIds"] = Audience("apple")
            }).Build();
            Verifier = new ProviderVerifier(config, clients);
        }

        public SignInRequest Request(string provider, string? token = null) => new(provider, token ?? Token(provider), Nonce);

        public string Token(string provider, Action<JwtPayload>? change = null, SigningCredentials? credentials = null, string algorithm = SecurityAlgorithms.RsaSha256)
        {
            var now = DateTimeOffset.UtcNow;
            var payload = new JwtPayload
            {
                ["iss"] = Issuer(provider), ["aud"] = Audience(provider), ["sub"] = "provider-subject",
                ["iat"] = now.AddMinutes(-5).ToUnixTimeSeconds(), ["nbf"] = now.AddMinutes(-5).ToUnixTimeSeconds(),
                ["exp"] = now.AddMinutes(5).ToUnixTimeSeconds(), ["nonce"] = Ids.Hash(Nonce),
                ["email"] = "member@gmail.com", ["email_verified"] = true
            };
            change?.Invoke(payload);
            var header = new JwtHeader(algorithm == "none" ? null : credentials ?? new SigningCredentials(key, algorithm));
            return new JwtSecurityTokenHandler().WriteToken(new JwtSecurityToken(header, payload));
        }

        public void Dispose() { clients.Dispose(); signingKey.Dispose(); }
    }
}
