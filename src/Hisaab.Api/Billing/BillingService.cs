using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Billing;

public sealed class BillingService(IAtomicStore store, IHttpClientFactory clients, IConfiguration config)
{
    public async Task<Entitlement> GetAsync(string userId, CancellationToken ct = default)
    {
        var grant = await store.GetAsync($"USER#{userId}", "SUPPORT_GRANT", ct);
        if (grant is not null && grant.Deserialize<Entitlement>().At(DateTimeOffset.UtcNow).AdFree) return grant.Deserialize<Entitlement>();
        var row = await store.GetAsync($"USER#{userId}", "ENTITLEMENT#ad_free", ct);
        return row?.Deserialize<Entitlement>().At(DateTimeOffset.UtcNow) ?? Entitlement.Free;
    }
    public async Task<Entitlement> RefreshAsync(string userId, CancellationToken ct = default)
    {
        var key = config["Hisaab:RevenueCat:SecretKey"];
        if (string.IsNullOrWhiteSpace(key)) throw new DomainException(503, "billing_unconfigured", "Purchases are not configured yet. No payment was taken by Hisaab.");
        for (var attempt = 0; attempt < 4; attempt++)
        {
            var account = await store.GetAsync($"USER#{userId}", "PROFILE", ct);
            if (account is null || account.Deserialize<UserAccount>().Status != "active") return Entitlement.Free;
            var previous = await store.GetAsync($"USER#{userId}", "ENTITLEMENT#ad_free", ct);
            using var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.revenuecat.com/v1/subscribers/{Uri.EscapeDataString(userId)}");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
            using var response = await clients.CreateClient().SendAsync(request, ct);
            Entitlement entitlement;
            if (response.StatusCode == HttpStatusCode.NotFound) entitlement = Entitlement.Free with { VerifiedAt = DateTimeOffset.UtcNow };
            else
            {
                if (!response.IsSuccessStatusCode) throw new DomainException(503, "verification_pending", "Purchase verification is pending. Try Restore Purchases again shortly.");
                using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct)); entitlement = Parse(json.RootElement, DateTimeOffset.UtcNow);
            }
            if ((config["Hisaab:RevenueCat:Environment"] ?? "PRODUCTION") == "PRODUCTION" && entitlement.Status.StartsWith("sandbox_", StringComparison.Ordinal)) entitlement = Entitlement.Free with { Status = "sandbox_ignored", VerifiedAt = DateTimeOffset.UtcNow };
            var due = await store.GetAsync("WORK#entitlement", userId, ct);
            var writes = new List<StoreMutation>{
                StoreMutation.Condition(account.Pk,account.Sk,account.Version),
                StoreMutation.Put(StoreRow.Create($"USER#{userId}","ENTITLEMENT#ad_free",(previous?.Version??0)+1,entitlement),previous?.Version),
                StoreMutation.Put(StoreRow.Create($"USER#{userId}",$"BILLING#{DateTimeOffset.UtcNow:O}#{Ids.New()}",1,entitlement),null),
                StoreMutation.Put(StoreRow.Create("WORK#entitlement",userId,(due?.Version??0)+1,new {userId,dueAt=DateTimeOffset.UtcNow.AddHours(1)}),due?.Version)
            };
            try { await store.TransactAsync(writes, ct); return entitlement; } catch (StoreConflictException) when (attempt < 3) { }
        }
        throw new DomainException(503, "verification_pending", "Purchase verification is pending. Try again shortly.");
    }
    public static Entitlement Parse(JsonElement root, DateTimeOffset now)
    {
        if (!root.TryGetProperty("subscriber", out var subscriber)) throw new DomainException(502, "billing_response_invalid", "Purchase verification is pending.");
        if (!subscriber.TryGetProperty("entitlements", out var entitlements) || !entitlements.TryGetProperty("ad_free", out var adFree)) return Entitlement.Free with { VerifiedAt = now };
        if (!adFree.TryGetProperty("expires_date", out var expiry)) throw new DomainException(502, "billing_response_invalid", "Purchase verification is pending.");
        var expires = Date(expiry); var storeName = (string?)null; var status = "active";
        var product = adFree.TryGetProperty("product_identifier", out var id) ? id.GetString() : null;
        if (product is not null && subscriber.TryGetProperty("subscriptions", out var subscriptions) && subscriptions.TryGetProperty(product, out var subscription))
        {
            if (subscription.TryGetProperty("store", out var s)) storeName = s.GetString();
            if (subscription.TryGetProperty("unsubscribe_detected_at", out var cancelled) && cancelled.ValueKind != JsonValueKind.Null) status = "cancelled_but_active";
            if (subscription.TryGetProperty("grace_period_expires_date", out var grace)) { var until = Date(grace); if (until > now && (expires is null || until > expires)) { expires = until; status = "grace"; } }
            if (subscription.TryGetProperty("is_sandbox", out var sandbox) && sandbox.ValueKind == JsonValueKind.True) status = "sandbox_" + status;
        }
        return new Entitlement(expires is null || expires > now, status, expires, storeName, now).At(now);
    }
    private static DateTimeOffset? Date(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.TryGetDateTimeOffset(out var date) ? date : throw new DomainException(502, "billing_response_invalid", "Purchase verification is pending.");
    public async Task AcceptWebhookAsync(string? authorization, JsonElement payload, CancellationToken ct = default)
    {
        var secret = config["Hisaab:RevenueCat:WebhookAuthorization"];
        if (string.IsNullOrWhiteSpace(secret) || authorization is null || !Ids.FixedEquals(secret, authorization)) throw new DomainException(401, "webhook_invalid", "Invalid webhook authorization.");
        if (!payload.TryGetProperty("event", out var item) || !item.TryGetProperty("id", out var idValue)) throw new DomainException(400, "webhook_invalid", "Missing event ID.");
        var id = idValue.GetString();
        if (string.IsNullOrWhiteSpace(id) || id.Length > 200) throw new DomainException(400, "webhook_invalid", "Invalid event ID.");
        var type = item.TryGetProperty("type", out var t) ? t.GetString() : "UNKNOWN";
        var expected = config["Hisaab:RevenueCat:Environment"] ?? "PRODUCTION";
        var env = item.TryGetProperty("environment", out var e) ? e.GetString() : null;
        if (env != expected && !(type == "TRANSFER" && env is null)) return;
        var users = new HashSet<string>(StringComparer.Ordinal);
        foreach (var field in new[] { "app_user_id", "original_app_user_id" })
            if (item.TryGetProperty(field, out var value) && value.ValueKind == JsonValueKind.String && Guid.TryParse(value.GetString(), out _)) users.Add(value.GetString()!);
        foreach (var field in new[] { "aliases", "transferred_from", "transferred_to" })
            if (item.TryGetProperty(field, out var values) && values.ValueKind == JsonValueKind.Array)
                foreach (var value in values.EnumerateArray()) if (value.ValueKind == JsonValueKind.String && Guid.TryParse(value.GetString(), out _)) users.Add(value.GetString()!);
        if (users.Count == 0) return; // Anonymous IDs cannot create accounts or grants.
        if (users.Count > 50) throw new DomainException(422, "webhook_identity_limit", "Too many account identifiers in one event.");
        var pk = $"BILLINGEVENT#{Ids.Hash(id)}";
        if (await store.GetAsync(pk, "META", ct) is not null) return;
        var receivedAt = DateTimeOffset.UtcNow;
        var writes = new List<StoreMutation> { StoreMutation.Put(StoreRow.Create(pk, "META", 1, new { id, type, userIds = users.ToArray(), receivedAt }), null) };
        foreach (var userId in users) writes.Add(StoreMutation.Put(StoreRow.Create("WORK#billing", Ids.Hash(id + ":" + userId), 1, new { id, userId, type, receivedAt }), null));
        if (item.TryGetProperty("app_user_id", out var owner) && Guid.TryParse(owner.GetString(), out _) && item.TryGetProperty("store", out var provider) && provider.ValueKind == JsonValueKind.String)
        {
            foreach (var field in new[] { "transaction_id", "original_transaction_id" })
            {
                if (!item.TryGetProperty(field, out var tx) || tx.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(tx.GetString())) continue;
                var txKey = $"STORE#{provider.GetString()}#{Ids.Hash(tx.GetString()!)}";
                if (writes.Any(w => w.Key.Pk == txKey)) continue;
                var known = await store.GetAsync(txKey, "OWNER", ct);
                if (known is null) writes.Add(StoreMutation.Put(StoreRow.Create(txKey, "OWNER", 1, new { userId = owner.GetString(), provider = provider.GetString(), transactionId = tx.GetString(), eventId = id }), null));
            }
        }
        try { await store.TransactAsync(writes, ct); }
        catch (StoreConflictException) { if (await store.GetAsync(pk, "META", ct) is null) throw; }
    }
}
