using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using Hisaab.Api.Identity;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hisaab.Api.Tests;

public sealed class AppleReturningSignInTests
{
    [Fact]
    public async Task ReturningAppleSignInRefreshesRevocationCredentialOnlyWhenExchangedIdentityMatches()
    {
        var exchanges = 0;
        var revocations = 0;
        var returnedIdentityToken = "matching-exchanged-token";
        var authorizationBodies = new List<string>();
        await using var factory = new ApiFactory
        {
            ProviderResponse = request =>
            {
                Assert.Equal("appleid.apple.com", request.RequestUri!.Host);
                if (request.RequestUri.AbsolutePath == "/auth/revoke")
                {
                    Assert.Contains("token=revocation-refresh-2", request.Content!.ReadAsStringAsync().GetAwaiter().GetResult());
                    revocations++;
                    return new HttpResponseMessage(HttpStatusCode.OK);
                }
                Assert.Equal("/auth/token", request.RequestUri.AbsolutePath);
                authorizationBodies.Add(request.Content!.ReadAsStringAsync().GetAwaiter().GetResult());
                exchanges++;
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new { id_token = returnedIdentityToken, refresh_token = $"revocation-refresh-{exchanges}" })
                };
            }
        };
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var verifier = new ReturningAppleVerifier();
        await using var host = factory.WithWebHostBuilder(builder =>
        {
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Hisaab:Auth:apple:PrivateKey"] = key.ExportPkcs8PrivateKeyPem(),
                ["Hisaab:Auth:apple:TeamId"] = "test-team",
                ["Hisaab:Auth:apple:KeyId"] = "test-key"
            }));
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IProviderVerifier>();
                services.AddSingleton<IProviderVerifier>(verifier);
            });
        });
        using var client = host.CreateClient();
        var protector = host.Services.GetRequiredService<TokenProtector>();
        var identityKey = IdentityService.IdentityKey("apple", "returning-account");
        var firstNonce = (await ApiSession.Json(client, HttpMethod.Get, "/v1/auth/challenge")).GetProperty("nonce").GetString()!;
        var firstSession = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/sign-in", new
        {
            provider = "apple", idToken = "client-token", nonce = firstNonce, authorizationCode = "fresh-code-1", displayName = "Apple member"
        });
        var firstIdentity = (await factory.Store.GetAsync(identityKey, "OWNER"))!.Deserialize<ProviderIdentity>();
        Assert.Equal("revocation-refresh-1", protector.Unprotect(firstIdentity.EncryptedRefreshToken!));

        var secondNonce = (await ApiSession.Json(client, HttpMethod.Get, "/v1/auth/challenge")).GetProperty("nonce").GetString()!;
        var secondSession = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/sign-in", new
        {
            provider = "apple", idToken = "client-token", nonce = secondNonce, authorizationCode = "fresh-code-2"
        });
        var refreshedRow = (await factory.Store.GetAsync(identityKey, "OWNER"))!;
        var refreshedIdentity = refreshedRow.Deserialize<ProviderIdentity>();
        Assert.Equal(firstSession.GetProperty("user").GetProperty("id").GetString(), secondSession.GetProperty("user").GetProperty("id").GetString());
        Assert.Equal(firstIdentity.UserId, refreshedIdentity.UserId);
        Assert.NotEqual(firstIdentity.EncryptedRefreshToken, refreshedIdentity.EncryptedRefreshToken);
        Assert.Equal("revocation-refresh-2", protector.Unprotect(refreshedIdentity.EncryptedRefreshToken!));
        Assert.Equal(2, exchanges);
        Assert.Contains("code=fresh-code-1", authorizationBodies[0]);
        Assert.Contains("code=fresh-code-2", authorizationBodies[1]);
        Assert.Equal(firstNonce, verifier.Requests[1].Nonce);
        Assert.Equal(secondNonce, verifier.Requests[3].Nonce);

        returnedIdentityToken = "wrong-subject-token";
        var wrongNonce = (await ApiSession.Json(client, HttpMethod.Get, "/v1/auth/challenge")).GetProperty("nonce").GetString()!;
        var error = await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.Unauthorized, new
        {
            provider = "apple", idToken = "client-token", nonce = wrongNonce, authorizationCode = "different-account-code"
        });
        Assert.Equal("apple_exchange_identity_invalid", error.GetProperty("code").GetString());
        var unchanged = (await factory.Store.GetAsync(identityKey, "OWNER"))!;
        Assert.Equal(refreshedRow.Version, unchanged.Version);
        Assert.Equal(refreshedIdentity.EncryptedRefreshToken, unchanged.Deserialize<ProviderIdentity>().EncryptedRefreshToken);
        Assert.Equal(3, exchanges);
        await host.Services.GetRequiredService<AppleTokens>().RevokeAsync(refreshedIdentity, CancellationToken.None);
        Assert.Equal(1, revocations);
    }
}
