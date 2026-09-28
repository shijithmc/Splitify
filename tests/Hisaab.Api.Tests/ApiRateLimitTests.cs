using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;

namespace Hisaab.Api.Tests;

public sealed class ApiRateLimitTests
{
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = DateTimeOffset.FromUnixTimeSeconds(1800000000);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    [Fact]
    public async Task ConcurrentInstancesShareOneCounterAndAColdStartDoesNotResetIt()
    {
        var store = new LocalAtomicStore(); var clock = new Clock();
        var rules = new[] { new RequestRateLimit("account", "alice", 7) };
        var results = await Task.WhenAll(Enumerable.Range(0, 30).Select(async _ =>
        {
            await Task.Yield();
            return await new DistributedRateLimiter(store, clock).AdmitAsync(rules);
        }));
        Assert.Equal(7, results.Count(result => result.Allowed));
        Assert.False((await new DistributedRateLimiter(store, clock).AdmitAsync(rules)).Allowed);
        var row = (await store.GetAsync($"RATE#account#{Ids.Hash("alice")}", "30000000"))!;
        Assert.Equal(7, row.Deserialize<RequestRateUsage>().Count);
        Assert.Equal(1800000120, row.ExpiresAtUnixSeconds);
        clock.Now = clock.Now.AddSeconds(59);
        Assert.Equal(1, (await new DistributedRateLimiter(store, clock).AdmitAsync(rules)).RetryAfterSeconds);
        clock.Now = clock.Now.AddSeconds(1);
        Assert.True((await new DistributedRateLimiter(store, clock).AdmitAsync(rules)).Allowed);
    }

    [Fact]
    public async Task DeniedSpecializedLimitDoesNotConsumeAnotherBucket()
    {
        var store = new LocalAtomicStore(); var limiter = new DistributedRateLimiter(store, new Clock());
        await limiter.AdmitAsync([new("ai", "alice", 1)]);
        Assert.False((await limiter.AdmitAsync([new("api", "alice", 1), new("ai", "alice", 1)])).Allowed);
        Assert.True((await limiter.AdmitAsync([new("api", "alice", 1)])).Allowed);
        Assert.True((await limiter.AdmitAsync([new("ai", "bob", 1)])).Allowed);
    }

    [Fact]
    public async Task IpIdentityIgnoresHeadersAndNormalizesIpv4AndIpv6()
    {
        var policies = Options.Create(new ApiRateLimitOptions { RequestsPerIpPerMinute = 1 });
        var limits = new ApiRateLimits(new(new LocalAtomicStore(), new Clock()), policies);
        async Task<bool> Admit(string ip)
        {
            var context = new DefaultHttpContext();
            context.Connection.RemoteIpAddress = IPAddress.Parse(ip);
            context.Request.Headers["X-Forwarded-For"] = Guid.NewGuid().ToString();
            context.Response.Body = new MemoryStream();
            return await limits.AdmitIngressAsync(context);
        }
        Assert.True(await Admit("192.0.2.1"));
        Assert.False(await Admit("::ffff:192.0.2.1"));
        Assert.True(await Admit("2001:db8:1:2::1"));
        Assert.False(await Admit("2001:db8:1:2::9999"));
        Assert.True(await Admit("2001:db8:1:3::1"));
    }

    [Fact]
    public async Task EveryPathIsLimitedBeforeAuthenticationIncludingInvalidTokensAndNotFoundRoutes()
    {
        using var factory = new ApiFactory();
        using var host = factory.WithWebHostBuilder(builder => Configure(builder, limits => limits.RequestsPerIpPerMinute = 2));
        using var client = host.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/v1/me")).StatusCode);
        client.DefaultRequestHeaders.Add("Authorization", "Bearer invalid");
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/does-not-exist")).StatusCode);
        client.DefaultRequestHeaders.Add("X-Forwarded-For", "203.0.113.50");
        using var response = await client.GetAsync("/health");
        await AssertLimited(response);
    }

    [Fact]
    public async Task AuthEndpointsShareAnIpLimitBeforeIssuingChallengesOrVerifyingTokens()
    {
        using var factory = new ApiFactory();
        using var host = factory.WithWebHostBuilder(builder => Configure(builder, limits => limits.AuthRequestsPerIpPerMinute = 2));
        using var client = host.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/v1/auth/challenge")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/v1/auth/challenge")).StatusCode);
        using var response = await client.PostAsJsonAsync("/v1/auth/sign-in", new { });
        await AssertLimited(response);
    }

    [Fact]
    public async Task AllAiEntryRoutesShareTheAccountLimitDespiteNewIdsKeysAndServerInstances()
    {
        using var factory = new ApiFactory();
        using var first = factory.WithWebHostBuilder(builder => Configure(builder, limits => limits.AiRequestsPerAccountPerMinute = 3));
        using var second = factory.WithWebHostBuilder(builder => Configure(builder, limits => limits.AiRequestsPerAccountPerMinute = 3));
        using var client = first.CreateClient();
        using var otherServer = second.CreateClient();
        var session = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/dev", new { displayName = "Alice" });
        var bearer = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", session.GetProperty("accessToken").GetString());
        client.DefaultRequestHeaders.Authorization = bearer;
        otherServer.DefaultRequestHeaders.Authorization = bearer;
        // Invalid bodies also consume admission; none can enqueue inference.
        foreach (var path in new[] { "/v1/groups/unknown/receipts", "/v1/receipts/a/complete", "/v1/receipts/b/retry" })
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, path);
            request.Headers.Add("Idempotency-Key", Guid.NewGuid().ToString());
            using var response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        }
        using var limited = await otherServer.PostAsJsonAsync("/V1/receipts/new/retry/", new { version = 1 });
        await AssertLimited(limited);
        Assert.Equal(HttpStatusCode.OK, (await otherServer.GetAsync("/v1/me")).StatusCode);
    }

    [Fact]
    public async Task GeneralAccountLimitAppliesAcrossEndpointsButKeepsAccountsSeparate()
    {
        using var factory = new ApiFactory();
        using var host = factory.WithWebHostBuilder(builder => Configure(builder, limits => limits.RequestsPerAccountPerMinute = 2));
        using var alice = host.CreateClient(); using var bob = host.CreateClient();
        foreach (var client in new[] { alice, bob })
        {
            var session = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/dev", new { displayName = "Member" });
            client.DefaultRequestHeaders.Authorization = new("Bearer", session.GetProperty("accessToken").GetString());
        }
        Assert.Equal(HttpStatusCode.OK, (await alice.GetAsync("/v1/me")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await alice.GetAsync("/v1/groups")).StatusCode);
        using var limited = await alice.GetAsync("/v1/balances");
        await AssertLimited(limited);
        Assert.Equal(HttpStatusCode.OK, (await bob.GetAsync("/v1/me")).StatusCode);
    }

    [Fact]
    public async Task AiIngressLimitRunsBeforeAuthenticationAndStoreFailureFailsClosed()
    {
        using var factory = new ApiFactory();
        using var host = factory.WithWebHostBuilder(builder => Configure(builder, limits => limits.AiRequestsPerIpPerMinute = 1));
        using var client = host.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsJsonAsync("/v1/receipts/a/retry", new { })).StatusCode);
        using var limited = await client.PostAsJsonAsync("/v1/groups/b/receipts", new { });
        await AssertLimited(limited);

        using var failingHost = factory.WithWebHostBuilder(builder => builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<IAtomicStore>(); services.AddSingleton<IAtomicStore>(new BrokenStore());
        }));
        using var failingClient = failingHost.CreateClient();
        Assert.Equal(HttpStatusCode.InternalServerError, (await failingClient.GetAsync("/health")).StatusCode);
    }

    private static void Configure(IWebHostBuilder builder, Action<ApiRateLimitOptions> configure) => builder.ConfigureTestServices(services =>
    {
        services.PostConfigure(configure);
        services.RemoveAll<TimeProvider>(); services.AddSingleton<TimeProvider>(new Clock());
    });

    private static async Task AssertLimited(HttpResponseMessage response)
    {
        Assert.Equal(HttpStatusCode.TooManyRequests, response.StatusCode);
        Assert.InRange(response.Headers.RetryAfter!.Delta!.Value.TotalSeconds, 1, 60);
        Assert.True(response.Headers.CacheControl!.NoStore);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("rate_limited", body.GetProperty("code").GetString());
        Assert.False(string.IsNullOrWhiteSpace(body.GetProperty("correlationId").GetString()));
    }

    private sealed class BrokenStore : IAtomicStore
    {
        public Task<StoreRow?> GetAsync(string pk, string sk, CancellationToken ct = default) => throw new IOException("Unavailable");
        public Task<StorePage> QueryAsync(string pk, string prefix, int limit = 100, string? cursor = null, CancellationToken ct = default) => throw new IOException();
        public Task TransactAsync(IReadOnlyList<StoreMutation> mutations, CancellationToken ct = default) => throw new IOException();
    }
}
