using System.Net;
using System.Text.Json;
using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hisaab.Api.Tests;

public sealed class PhoneOtpJourneyTests
{
    private const string Phone = "+919876543210";
    private const string Code = "123456";

    [Fact]
    public async Task DisabledPhoneSignInFailsClosedWithoutCallingSmsProvider()
    {
        await using var factory = new ApiFactory();
        var error = await ApiSession.Error(factory.CreateClient(), HttpMethod.Post, "/v1/auth/phone/challenge", HttpStatusCode.ServiceUnavailable, new { phoneNumber = Phone });
        Assert.Equal("phone_unavailable", error.GetProperty("code").GetString());
    }

    [Theory]
    [InlineData("9876543210")]
    [InlineData("+019876543210")]
    [InlineData("+91 9876543210")]
    [InlineData("+9198765432101234")]
    [InlineData("")]
    public async Task InvalidPhoneNumbersNeverSendSms(string phoneNumber)
    {
        using var test = new Context();
        await ApiSession.Error(test.Client(), HttpMethod.Post, "/v1/auth/phone/challenge", HttpStatusCode.UnprocessableEntity, new { phoneNumber });
        Assert.Equal(0, test.Provider.Sends);
    }

    [Fact]
    public async Task PhoneSignInCreatesNormalSessionConsumesChallengeAndReturnsSameAccount()
    {
        using var test = new Context(); using var client = test.Client();
        var nonce = await Challenge(client);
        var row = await test.Factory.Store.GetAsync($"CHALLENGE#{Ids.Hash(nonce)}", "META");
        Assert.DoesNotContain(Phone, row!.Data.GetRawText());
        var session = await SignIn(client, nonce);
        client.DefaultRequestHeaders.Authorization = new("Bearer", session.GetProperty("accessToken").GetString());
        var me = await ApiSession.Json(client, HttpMethod.Get, "/v1/me");
        var userId = me.GetProperty("user").GetProperty("id").GetString();
        Assert.Equal("Phone member", me.GetProperty("user").GetProperty("displayName").GetString());
        Assert.Null(await test.Factory.Store.GetAsync(row.Pk, row.Sk));
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.Unauthorized, new { provider = "phone", idToken = Code, nonce });
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        var returning = await SignIn(client, await Challenge(client));
        Assert.Equal(userId, returning.GetProperty("user").GetProperty("id").GetString());
        var refreshed = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/refresh", new { refreshToken = returning.GetProperty("refreshToken").GetString() });
        Assert.Equal(userId, refreshed.GetProperty("user").GetProperty("id").GetString());
    }

    [Fact]
    public async Task IncorrectCodeCanRetryButFiveAttemptsExhaustChallenge()
    {
        using var test = new Context(); using var client = test.Client();
        var nonce = await Challenge(client);
        for (var attempt = 0; attempt < 5; attempt++)
            await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.Unauthorized, new { provider = "phone", idToken = "000000", nonce });
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.Unauthorized, new { provider = "phone", idToken = Code, nonce });
        Assert.Equal(5, test.Provider.Checks);
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        nonce = await Challenge(client);
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.Unauthorized, new { provider = "phone", idToken = "000000", nonce });
        await SignIn(client, nonce);
    }

    [Fact]
    public async Task ExpiredAndOrdinaryOAuthChallengesCannotVerifyPhoneCode()
    {
        using var test = new Context(); using var client = test.Client();
        var nonce = await Challenge(client);
        test.Clock.Advance(TimeSpan.FromMinutes(11));
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.Unauthorized, new { provider = "phone", idToken = Code, nonce });
        var ordinary = await ApiSession.Json(client, HttpMethod.Get, "/v1/auth/challenge");
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.Unauthorized, new { provider = "phone", idToken = Code, nonce = ordinary.GetProperty("nonce").GetString() });
        Assert.Equal(0, test.Provider.Checks);
    }

    [Fact]
    public async Task ConcurrentVerificationCreatesExactlyOneSession()
    {
        using var test = new Context(); using var client = test.Client();
        var nonce = await Challenge(client);
        var responses = await Task.WhenAll(Enumerable.Range(0, 2).Select(_ => ApiSession.Send(client, HttpMethod.Post, "/v1/auth/sign-in", new { provider = "phone", idToken = Code, nonce })));
        try { Assert.Single(responses, response => response.StatusCode == HttpStatusCode.OK); Assert.Single(responses, response => !response.IsSuccessStatusCode); }
        finally { foreach (var response in responses) response.Dispose(); }
    }

    [Fact]
    public async Task LinkingRequiresRecentSessionAndBindsChallengeToPurposeAndSession()
    {
        using var test = new Context(); using var alice = test.Client(); using var bob = test.Client();
        var aliceSession = await Dev(alice); await Dev(bob);
        var aliceId = aliceSession.GetProperty("user").GetProperty("id").GetString();
        var profile = (await test.Factory.Store.GetAsync($"USER#{aliceId}", "PROFILE"))!;
        await test.Factory.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(profile.Pk, profile.Sk, profile.Version + 1, profile.Deserialize<UserAccount>() with { Email = "alice@example.com" }), profile.Version)]);
        var nonce = await Challenge(alice, "link");
        await ApiSession.Error(alice, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.Unauthorized, new { provider = "phone", idToken = Code, nonce });
        await ApiSession.Error(bob, HttpMethod.Post, "/v1/auth/link", HttpStatusCode.Unauthorized, new { provider = "phone", idToken = Code, nonce });
        var linked = await ApiSession.Json(alice, HttpMethod.Post, "/v1/auth/link", new { provider = "phone", idToken = Code, nonce });
        Assert.Equal(aliceSession.GetProperty("user").GetProperty("id").GetString(), linked.GetProperty("id").GetString());
        Assert.Equal(1, test.Provider.Checks);
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        var returning = await SignIn(test.Client(), await Challenge(test.Client()));
        Assert.Equal(linked.GetProperty("id").GetString(), returning.GetProperty("user").GetProperty("id").GetString());
        Assert.Equal("alice@example.com", returning.GetProperty("user").GetProperty("email").GetString());
        await AgeSession(test, alice);
        await ApiSession.Error(alice, HttpMethod.Post, "/v1/auth/phone/link/challenge", HttpStatusCode.Unauthorized, new { phoneNumber = "+14155552671" });
    }

    [Fact]
    public async Task PhoneAlreadyOwnedByAnotherAccountCannotBeSilentlyMerged()
    {
        using var test = new Context(); using var alice = test.Client(); using var bob = test.Client();
        var original = await SignIn(alice, await Challenge(alice)); await Dev(bob);
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        var nonce = await Challenge(bob, "link");
        var error = await ApiSession.Error(bob, HttpMethod.Post, "/v1/auth/link", HttpStatusCode.Conflict, new { provider = "phone", idToken = Code, nonce });
        Assert.Equal("account_merge_required", error.GetProperty("code").GetString());
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        var returning = await SignIn(alice, await Challenge(alice));
        Assert.Equal(original.GetProperty("user").GetProperty("id").GetString(), returning.GetProperty("user").GetProperty("id").GetString());
    }

    [Fact]
    public async Task PendingChallengeSurvivesCredentialRefreshButRejectsAnotherSession()
    {
        using var test = new Context(); using var client = test.Client(); using var other = test.Client();
        var original = await SignIn(client, await Challenge(client));
        client.DefaultRequestHeaders.Authorization = new("Bearer", original.GetProperty("accessToken").GetString());
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        var separate = await SignIn(other, await Challenge(other));
        other.DefaultRequestHeaders.Authorization = new("Bearer", separate.GetProperty("accessToken").GetString());
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        var nonce = await Challenge(client, "reauthenticate");
        await ApiSession.Error(other, HttpMethod.Post, "/v1/auth/phone/reauthenticate", HttpStatusCode.Unauthorized, new { nonce, code = Code });
        var refreshed = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/refresh", new { refreshToken = original.GetProperty("refreshToken").GetString() });
        client.DefaultRequestHeaders.Authorization = new("Bearer", refreshed.GetProperty("accessToken").GetString());
        var reauthenticated = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/phone/reauthenticate", new { nonce, code = Code });
        Assert.Equal(original.GetProperty("user").GetProperty("id").GetString(), reauthenticated.GetProperty("user").GetProperty("id").GetString());
    }

    [Fact]
    public async Task PhoneReauthenticationKeepsAccountRotatesCredentialsAndEnablesDeletion()
    {
        using var test = new Context(); using var client = test.Client();
        var original = await SignIn(client, await Challenge(client));
        client.DefaultRequestHeaders.Authorization = new("Bearer", original.GetProperty("accessToken").GetString());
        await AgeSession(test, client);
        await ApiSession.Error(client, HttpMethod.Delete, "/v1/me", HttpStatusCode.Unauthorized, new { confirm = true });
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/phone/reauthenticate/challenge", HttpStatusCode.UnprocessableEntity, new { phoneNumber = "+14155552671" });
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        var nonce = await Challenge(client, "reauthenticate");
        var session = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/phone/reauthenticate", new { nonce, code = Code });
        Assert.Equal(original.GetProperty("user").GetProperty("id").GetString(), session.GetProperty("user").GetProperty("id").GetString());
        await ApiSession.Error(client, HttpMethod.Get, "/v1/me", HttpStatusCode.Unauthorized);
        await ApiSession.Error(test.Client(), HttpMethod.Post, "/v1/auth/refresh", HttpStatusCode.Unauthorized, new { refreshToken = original.GetProperty("refreshToken").GetString() });
        client.DefaultRequestHeaders.Authorization = new("Bearer", session.GetProperty("accessToken").GetString());
        var userId = session.GetProperty("user").GetProperty("id").GetString();
        var identities = (await test.Factory.Store.QueryAsync($"USER#{userId}", "IDENTITY#")).Items;
        await ApiSession.Json(client, HttpMethod.Delete, "/v1/me", new { confirm = true });
        foreach (var identity in identities) Assert.Null(await test.Factory.Store.GetAsync(identity.Data.GetProperty("key").GetString()!, "OWNER"));
    }

    [Fact]
    public async Task SendCooldownAndGlobalBudgetAreSharedAcrossInstances()
    {
        using var test = new Context(maxSmsPerDay: 1); using var first = test.Client(); using var second = test.Client();
        await Challenge(first);
        using var cooldown = await ApiSession.Send(second, HttpMethod.Post, "/v1/auth/phone/challenge", new { phoneNumber = Phone });
        Assert.Equal(HttpStatusCode.TooManyRequests, cooldown.StatusCode);
        Assert.InRange(cooldown.Headers.RetryAfter!.Delta!.Value.TotalSeconds, 1, 60);
        Assert.True(cooldown.Headers.CacheControl!.NoStore);
        test.Clock.Advance(TimeSpan.FromSeconds(61));
        await ApiSession.Error(second, HttpMethod.Post, "/v1/auth/phone/challenge", HttpStatusCode.TooManyRequests, new { phoneNumber = "+14155552671" });
        Assert.Equal(1, test.Provider.Sends);
    }

    private static async Task<string> Challenge(HttpClient client, string? purpose = null) => (await ApiSession.Json(client, HttpMethod.Post, $"/v1/auth/phone/{(purpose is null ? "" : purpose + "/")}challenge", new { phoneNumber = Phone })).GetProperty("nonce").GetString()!;
    private static Task<JsonElement> SignIn(HttpClient client, string nonce) => ApiSession.Json(client, HttpMethod.Post, "/v1/auth/sign-in", new { provider = "phone", idToken = Code, nonce, displayName = "Phone member" });
    private static async Task<JsonElement> Dev(HttpClient client)
    {
        var session = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/dev", new { displayName = "Member" });
        client.DefaultRequestHeaders.Authorization = new("Bearer", session.GetProperty("accessToken").GetString()); return session;
    }
    private static async Task AgeSession(Context test, HttpClient client)
    {
        var row = (await test.Factory.Store.GetAsync($"SESSION#{Ids.Hash(client.DefaultRequestHeaders.Authorization!.Parameter!)}", "META"))!;
        await test.Factory.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, row.Version + 1, row.Deserialize<SessionRecord>() with { CreatedAt = DateTimeOffset.UtcNow.AddMinutes(-11) }), row.Version)]);
    }
    private sealed class Context : IDisposable
    {
        public ApiFactory Factory { get; } = new();
        public TestPhoneProvider Provider { get; } = new();
        public Clock Clock { get; } = new();
        private readonly WebApplicationFactory<Program> host;
        public Context(int maxSmsPerDay = 100)
        {
            host = Factory.WithWebHostBuilder(builder => {
                builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?> { ["Hisaab:Auth:Phone:MaxSmsPerDay"] = maxSmsPerDay.ToString() }));
                builder.ConfigureTestServices(services => {
                    services.RemoveAll<IPhoneOtpProvider>(); services.AddSingleton<IPhoneOtpProvider>(Provider);
                    services.RemoveAll<TimeProvider>(); services.AddSingleton<TimeProvider>(Clock);
                });
            });
        }
        public HttpClient Client() => host.CreateClient();
        public void Dispose() { host.Dispose(); Factory.Dispose(); }
    }
    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UtcNow;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan by) => now += by;
    }
    private sealed class TestPhoneProvider : IPhoneOtpProvider
    {
        public int Sends; public int Checks;
        public void EnsureConfigured() { }
        public Task<string> SendAsync(string phoneNumber, CancellationToken ct) { Interlocked.Increment(ref Sends); return Task.FromResult("VE" + Guid.NewGuid().ToString("N")); }
        public Task<bool> CheckAsync(string verificationSid, string phoneNumber, string code, CancellationToken ct) { Interlocked.Increment(ref Checks); return Task.FromResult(code == Code); }
    }
}
