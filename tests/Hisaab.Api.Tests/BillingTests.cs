using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Hisaab.Api.Billing;
using Hisaab.Domain;

namespace Hisaab.Api.Tests;

public sealed class BillingTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 26, 12, 0, 0, TimeSpan.Zero);

    [Theory]
    [InlineData(1, null, false, true, "active")]
    [InlineData(-1, null, false, false, "expired")]
    [InlineData(0, null, false, false, "expired")]
    [InlineData(1, null, true, true, "cancelled_but_active")]
    [InlineData(-1, 1, false, true, "grace")]
    [InlineData(-2, -1, false, false, "expired")]
    public void VerifiedStoreSnapshotDeterminesLifecycle(int expiryDays, int? graceDays, bool cancelled, bool adFree, string status)
    {
        var json = Snapshot(Now.AddDays(expiryDays), graceDays is null ? null : Now.AddDays(graceDays.Value), cancelled);
        var entitlement = BillingService.Parse(json, Now);
        Assert.Equal(adFree, entitlement.AdFree);
        Assert.Equal(status, entitlement.Status);
        Assert.Equal("app_store", entitlement.Store);
        Assert.Equal(Now, entitlement.VerifiedAt);
    }

    [Fact]
    public void LifetimeAndMissingEntitlementsAreHandled()
    {
        Assert.True(BillingService.Parse(Snapshot(null, null, false), Now).AdFree);
        var free = BillingService.Parse(JsonSerializer.SerializeToElement(new { subscriber = new { entitlements = new { } } }), Now);
        Assert.False(free.AdFree);
        Assert.Equal("free", free.Status);
        Assert.Throws<DomainException>(() => BillingService.Parse(JsonSerializer.SerializeToElement(new { }), Now));
    }

    [Fact]
    public async Task ForgedWebhookCannotGrantPremium()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var payload = new { @event = new { id = "forged", app_user_id = user.UserId, environment = "PRODUCTION", type = "INITIAL_PURCHASE", entitlement_ids = new[] { "ad_free" } } };
        await ApiSession.Error(factory.CreateClient(), HttpMethod.Post, "/v1/billing/webhook", HttpStatusCode.Unauthorized, payload);
        var entitlement = await ApiSession.Json(user.Client, HttpMethod.Get, "/v1/billing/entitlement");
        Assert.False(entitlement.GetProperty("adFree").GetBoolean());
        Assert.Empty((await factory.Store.QueryAsync("WORK#billing", "")).Items);
    }

    [Fact]
    public async Task AuthorizedWebhookIsDeduplicatedButNeverDirectlyGrantsPremium()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var client = factory.CreateClient();
        client.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", "Bearer integration-test-webhook-key");
        var payload = new { @event = new { id = "real-event", app_user_id = user.UserId, environment = "PRODUCTION", type = "INITIAL_PURCHASE" } };
        for (var i = 0; i < 2; i++)
        {
            using var response = await ApiSession.Send(client, HttpMethod.Post, "/v1/billing/webhook", payload);
            Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        }
        Assert.Single((await factory.Store.QueryAsync("WORK#billing", "")).Items);
        var entitlement = await ApiSession.Json(user.Client, HttpMethod.Get, "/v1/billing/entitlement");
        Assert.False(entitlement.GetProperty("adFree").GetBoolean());
    }

    [Fact]
    public async Task SandboxWebhookCannotQueueProductionGrant()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var client = factory.CreateClient();
        client.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", "Bearer integration-test-webhook-key");
        using var response = await ApiSession.Send(client, HttpMethod.Post, "/v1/billing/webhook",
            new { @event = new { id = "sandbox", app_user_id = user.UserId, environment = "SANDBOX", type = "INITIAL_PURCHASE" } });
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        Assert.Empty((await factory.Store.QueryAsync("WORK#billing", "")).Items);
    }

    [Theory]
    [InlineData("PRODUCTION", false)]
    [InlineData("SANDBOX", true)]
    public async Task SandboxRestSnapshotRequiresSandboxEnvironment(string environment, bool allowed)
    {
        await using var factory = new ApiFactory
        {
            BillingEnvironment = environment,
            ProviderResponse = request =>
            {
                Assert.Equal("api.revenuecat.com", request.RequestUri!.Host);
                Assert.Equal("Bearer", request.Headers.Authorization?.Scheme);
                return new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = JsonContent.Create(new
                    {
                        subscriber = new
                        {
                            entitlements = new { ad_free = new { expires_date = DateTimeOffset.UtcNow.AddDays(30), product_identifier = "annual" } },
                            subscriptions = new { annual = new { store = "play_store", is_sandbox = true } }
                        }
                    })
                };
            }
        };
        var user = await ApiSession.Login(factory, "Alice");
        var refreshed = await ApiSession.Json(user.Client, HttpMethod.Post, "/v1/billing/refresh");
        Assert.Equal(allowed, refreshed.GetProperty("adFree").GetBoolean());
        var stored = await ApiSession.Json(user.Client, HttpMethod.Get, "/v1/billing/entitlement");
        Assert.Equal(allowed, stored.GetProperty("adFree").GetBoolean());
    }

    [Fact]
    public async Task FreshRefundSnapshotRevokesPremiumAndOldWebhookCannotReviveIt()
    {
        var verifiedPremium = true;
        await using var factory = new ApiFactory
        {
            ProviderResponse = _ => new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(verifiedPremium
                    ? Snapshot(DateTimeOffset.UtcNow.AddDays(30), null, false)
                    : JsonSerializer.SerializeToElement(new { subscriber = new { entitlements = new { } } }))
            }
        };
        var user = await ApiSession.Login(factory, "Alice");
        Assert.True((await ApiSession.Json(user.Client, HttpMethod.Post, "/v1/billing/refresh")).GetProperty("adFree").GetBoolean());
        verifiedPremium = false;
        Assert.False((await ApiSession.Json(user.Client, HttpMethod.Post, "/v1/billing/refresh")).GetProperty("adFree").GetBoolean());
        var webhook = factory.CreateClient();
        webhook.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", "Bearer integration-test-webhook-key");
        var oldEvent = new { @event = new { id = "old-renewal", app_user_id = user.UserId, environment = "PRODUCTION", type = "RENEWAL" } };
        for (var i = 0; i < 2; i++)
        {
            using var response = await ApiSession.Send(webhook, HttpMethod.Post, "/v1/billing/webhook", oldEvent);
            Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        }
        Assert.False((await ApiSession.Json(user.Client, HttpMethod.Get, "/v1/billing/entitlement")).GetProperty("adFree").GetBoolean());
        Assert.Single((await factory.Store.QueryAsync("WORK#billing", "")).Items);
    }

    private static JsonElement Snapshot(DateTimeOffset? expires, DateTimeOffset? grace, bool cancelled) => JsonSerializer.SerializeToElement(new
    {
        subscriber = new
        {
            entitlements = new { ad_free = new { expires_date = expires, product_identifier = "annual" } },
            subscriptions = new { annual = new { store = "app_store", grace_period_expires_date = grace, unsubscribe_detected_at = cancelled ? Now.AddDays(-1) : (DateTimeOffset?)null, is_sandbox = false } }
        }
    });
}
