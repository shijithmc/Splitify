using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Extensions.Configuration;

namespace Hisaab.Api.Tests;

public sealed class AppleSecurityTests
{
    [Theory]
    [InlineData("other-apple-account", "com.hisaab.service")]
    [InlineData("expected-apple-account", "com.other.service")]
    public async Task ExchangedTokensMustMatchVerifiedAccountAndAudience(string subject, string audience)
    {
        using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var config = AppleConfiguration(signingKey);
        var verifier = new AppleBindingVerifier(subject, audience);
        using var clients = new TestHttpClientFactory(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new { id_token = "exchanged-id-token", refresh_token = "wrong-account-refresh" })
        });
        var tokens = new AppleTokens(config, clients, new TokenProtector(config), verifier);
        var error = await Assert.ThrowsAsync<DomainException>(() => tokens.ExchangeAsync(
            "authorization-code", "com.hisaab.service", "expected-apple-account", "original-nonce", CancellationToken.None));
        Assert.Equal(401, error.Status);
        Assert.Equal("apple_exchange_identity_invalid", error.Code);
        Assert.Equal("apple", verifier.LastRequest?.Provider);
        Assert.Equal("exchanged-id-token", verifier.LastRequest?.IdToken);
        Assert.Equal("original-nonce", verifier.LastRequest?.Nonce);
    }

    [Fact]
    public async Task MatchingExchangeEncryptsRefreshTokenAfterIdentityVerification()
    {
        using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var config = AppleConfiguration(signingKey);
        var verifier = new AppleBindingVerifier("expected-apple-account", "com.hisaab.service");
        using var clients = new TestHttpClientFactory(request =>
        {
            Assert.Equal("https://appleid.apple.com/auth/token", request.RequestUri!.AbsoluteUri);
            Assert.Equal(HttpMethod.Post, request.Method);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new { id_token = "matching-id-token", refresh_token = "valid-refresh-token" })
            };
        });
        var protector = new TokenProtector(config);
        var tokens = new AppleTokens(config, clients, protector, verifier);
        var encrypted = await tokens.ExchangeAsync("code", "com.hisaab.service", "expected-apple-account", "nonce", CancellationToken.None);
        Assert.NotEqual("valid-refresh-token", encrypted);
        Assert.Equal("valid-refresh-token", protector.Unprotect(encrypted));
    }

    [Theory]
    [InlineData("app.hisaab.hisaab", false)]
    [InlineData("com.hisaab.service", true)]
    public async Task CodeExchangeAddsExactRedirectOnlyForServicesId(string audience, bool webFlow)
    {
        using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var config = AppleConfiguration(signingKey);
        const string redirect = "https://auth.hisaab.example/v1/auth/apple/callback";
        config["Hisaab:Auth:apple:ClientIds"] = "app.hisaab.hisaab,com.hisaab.service";
        config["Hisaab:Auth:apple:ServiceId"] = "com.hisaab.service";
        config["Hisaab:Auth:apple:RedirectUri"] = redirect;
        using var clients = new TestHttpClientFactory(request =>
        {
            var fields = QueryHelpers.ParseQuery(request.Content!.ReadAsStringAsync().GetAwaiter().GetResult());
            Assert.Equal(audience, fields["client_id"]);
            Assert.Equal("authorization_code", fields["grant_type"]);
            Assert.Equal("code", fields["code"]);
            Assert.Equal(webFlow, fields.ContainsKey("redirect_uri"));
            if (webFlow) Assert.Equal(redirect, fields["redirect_uri"]);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new { id_token = "matching-id-token", refresh_token = "refresh" })
            };
        });
        var tokens = new AppleTokens(config, clients, new TokenProtector(config), new AppleBindingVerifier("subject", audience));
        await tokens.ExchangeAsync("code", audience, "subject", "nonce", CancellationToken.None);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("http://auth.hisaab.example/v1/auth/apple/callback")]
    [InlineData("https://localhost/v1/auth/apple/callback")]
    [InlineData("https://127.0.0.1/v1/auth/apple/callback")]
    [InlineData("https://auth.hisaab.example/callback#fragment")]
    [InlineData("https://user:password@auth.hisaab.example/callback")]
    public async Task ServicesIdExchangeRejectsInvalidRedirectBeforeSendingCode(string? redirect)
    {
        using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var config = AppleConfiguration(signingKey);
        config["Hisaab:Auth:apple:ServiceId"] = "com.hisaab.service";
        config["Hisaab:Auth:apple:RedirectUri"] = redirect;
        using var clients = new TestHttpClientFactory(_ => throw new InvalidOperationException("An invalid redirect must not send the authorization code."));
        var tokens = new AppleTokens(config, clients, new TokenProtector(config), new AppleBindingVerifier("subject", "com.hisaab.service"));
        var error = await Assert.ThrowsAsync<DomainException>(() => tokens.ExchangeAsync("code", "com.hisaab.service", "subject", "nonce", CancellationToken.None));
        Assert.Equal(503, error.Status);
        Assert.Equal("apple_android_unconfigured", error.Code);
    }

    [Theory]
    [InlineData("short")]
    [InlineData("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")]
    public async Task AndroidCallbackRejectsMalformedOrUnknownState(string state)
    {
        await using var factory = new ApiFactory();
        await using var host = AndroidHost(factory);
        using var client = host.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
        using var response = await client.PostAsync("/v1/auth/apple/callback", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["state"] = state,
            ["code"] = "code",
            ["id_token"] = "token"
        }));
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("callback_state_invalid", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString());
        Assert.Null(response.Headers.Location);
    }

    [Fact]
    public async Task AndroidCallbackRejectsExpiredState()
    {
        await using var factory = new ApiFactory();
        await using var host = AndroidHost(factory);
        using var client = host.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
        var challenge = await ApiSession.Json(client, HttpMethod.Get, "/v1/auth/challenge");
        var state = challenge.GetProperty("nonce").GetString()!;
        var row = (await factory.Store.GetAsync($"CHALLENGE#{Ids.Hash(state)}", "META"))!;
        await factory.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, row.Version + 1,
            new ChallengeRecord(DateTimeOffset.UtcNow.AddSeconds(-1))), row.Version)]);
        using var response = await client.PostAsync("/v1/auth/apple/callback", new FormUrlEncodedContent(new Dictionary<string, string> { ["state"] = state }));
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Equal("callback_state_invalid", (await response.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("code").GetString());
        Assert.Null(response.Headers.Location);
    }

    [Fact]
    public async Task AndroidCallbackUsesOnlyFixedDestinationAndEscapesEveryReturnedField()
    {
        await using var factory = new ApiFactory();
        await using var host = AndroidHost(factory);
        using var client = host.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
        var state = (await ApiSession.Json(client, HttpMethod.Get, "/v1/auth/challenge")).GetProperty("nonce").GetString()!;
        const string code = "code +&/#;=%\r\nユ";
        const string idToken = "token&next=https://evil.example/#Intent;package=evil.app;end";
        const string errorDescription = "cancelled + & reason";
        using var response = await client.PostAsync("/v1/auth/apple/callback", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["state"] = state,
            ["code"] = code,
            ["id_token"] = idToken,
            ["error_description"] = errorDescription,
            ["redirect_uri"] = "https://evil.example",
            ["package"] = "evil.app",
            ["scheme"] = "javascript"
        }));
        Assert.Equal(HttpStatusCode.Redirect, response.StatusCode);
        var expected = $"intent://callback?state={Uri.EscapeDataString(state)}&code={Uri.EscapeDataString(code)}&id_token={Uri.EscapeDataString(idToken)}&error_description={Uri.EscapeDataString(errorDescription)}#Intent;package=com.hisaab.app;scheme=signinwithapple;end";
        Assert.Equal(expected, response.Headers.Location?.OriginalString);
        Assert.True(response.Headers.CacheControl?.NoStore);
        Assert.Equal("no-referrer", Assert.Single(response.Headers.GetValues("Referrer-Policy")));
    }

    [Fact]
    public async Task AndroidCallbackRejectsJsonAndInvalidConfiguredPackage()
    {
        await using var factory = new ApiFactory();
        await using var host = AndroidHost(factory);
        using var client = host.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/apple/callback", HttpStatusCode.BadRequest, new { state = new string('a', 64) });
        await using var invalidHost = AndroidHost(factory, "com.hisaab.app;scheme=javascript");
        using var invalidClient = invalidHost.CreateClient(new WebApplicationFactoryClientOptions { AllowAutoRedirect = false });
        using var response = await invalidClient.PostAsync("/v1/auth/apple/callback", new FormUrlEncodedContent(new Dictionary<string, string> { ["state"] = new string('a', 64) }));
        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.Null(response.Headers.Location);
    }

    private static WebApplicationFactory<Program> AndroidHost(ApiFactory factory, string package = "com.hisaab.app") =>
        factory.WithWebHostBuilder(builder => builder.ConfigureAppConfiguration((_, config) =>
            config.AddInMemoryCollection(new Dictionary<string, string?> { ["Hisaab:Auth:apple:AndroidPackage"] = package })));

    private static IConfiguration AppleConfiguration(ECDsa signingKey) => new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
    {
        ["Hisaab:Auth:apple:PrivateKey"] = signingKey.ExportPkcs8PrivateKeyPem(),
        ["Hisaab:Auth:apple:TeamId"] = "test-team",
        ["Hisaab:Auth:apple:KeyId"] = "test-key",
        ["Hisaab:EncryptionKey"] = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
    }).Build();
}
