using System.Text.Json;
using Hisaab.Api.Identity;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Shared;

public sealed class CommandExecutor(IAtomicStore store)
{
    public async Task<JsonElement> ExecuteAsync(Actor actor, string key, string route, object request, Func<Task<MutationResult>> action, CancellationToken ct = default)
    {
        if (!Guid.TryParse(key, out _)) throw new DomainException(400, "idempotency_required", "Use a UUID Idempotency-Key for this change.");
        var pk = $"USER#{actor.User.Id}";
        var sk = $"COMMAND#{key}";
        var digest = Ids.Hash(route + JsonSerializer.Serialize(request, JsonDefaults.Options));
        for (var attempt = 0; attempt < 6; attempt++)
        {
            var existing = await store.GetAsync(pk, sk, ct);
            if (existing is not null)
            {
                var saved = existing.Deserialize<CommandResult>();
                if (saved.Digest != digest) throw new DomainException(409, "idempotency_mismatch", "This request key was already used for another change.");
                return saved.Result;
            }
            var active = await store.GetAsync($"USER#{actor.User.Id}", "PROFILE", ct);
            var session = await store.GetAsync($"SESSION#{actor.SessionHash}", "META", ct);
            if (active is null || active.Deserialize<UserAccount>().Status != "active" || session is null || session.Deserialize<SessionRecord>().AccessExpiresAt <= DateTimeOffset.UtcNow)
                throw new DomainException(401, "session_expired", "Sign in again.");
            StoreRow? limit = null;
            var limited = route == "groups:create" || route.EndsWith(":invite", StringComparison.Ordinal);
            var limitKey = $"LIMIT#{(route == "groups:create" ? "group" : "invite")}#{DateTimeOffset.UtcNow:yyyyMMddHHmm}";
            if (limited)
            {
                limit = await store.GetAsync(pk, limitKey, ct);
                if (limit is not null && limit.Data.GetProperty("count").GetInt32() >= 10) throw new DomainException(429, "rate_limited", "Too many requests. Please try again in a minute.");
            }
            var result = await action();
            var json = JsonSerializer.SerializeToElement(result.Result, JsonDefaults.Options);
            var writes = result.Writes.ToList();
            if (limited) writes.Add(StoreMutation.Put(StoreRow.Create(pk, limitKey, (limit?.Version ?? 0) + 1, new { count = (limit?.Data.GetProperty("count").GetInt32() ?? 0) + 1 }, DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()), limit?.Version));
            if (!writes.Any(x => x.Key == new StoreKey(active.Pk, active.Sk))) writes.Add(StoreMutation.Condition(active.Pk, active.Sk, active.Version));
            if (!writes.Any(x => x.Key == new StoreKey(session.Pk, session.Sk))) writes.Add(StoreMutation.Condition(session.Pk, session.Sk, session.Version));
            writes.Add(StoreMutation.Put(StoreRow.Create(pk, sk, 1, new CommandResult(digest, json), DateTimeOffset.UtcNow.AddDays(30).ToUnixTimeSeconds()), null));
            try { await store.TransactAsync(writes, ct); return json; }
            catch (StoreConflictException) when (attempt < 5) { await Task.Delay(Random.Shared.Next(10, 40) * (attempt + 1), ct); }
        }
        throw new DomainException(409, "concurrent_change", "Another change is in progress. Refresh and try again.");
    }
}
