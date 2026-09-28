using System.Globalization;
using Hisaab.Application.Storage;

namespace Hisaab.Api.Shared;

public sealed record RequestRateLimit(string Scope, string Subject, int Limit);
public sealed record RequestRateUsage(int Count);
public sealed record RateLimitDecision(bool Allowed, int RetryAfterSeconds);

/// <summary>Shared, conditional counters; Lambda scale-out cannot replenish an allowance.</summary>
public sealed class DistributedRateLimiter(IAtomicStore store, TimeProvider clock)
{
    public async Task<RateLimitDecision> AdmitAsync(IReadOnlyList<RequestRateLimit> limits, CancellationToken ct = default)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            var now = clock.GetUtcNow().ToUnixTimeSeconds();
            var window = now / 60;
            var retryAfter = (int)((window + 1) * 60 - now);
            var writes = new List<StoreMutation>();
            foreach (var limit in limits)
            {
                var pk = $"RATE#{limit.Scope}#{Ids.Hash(limit.Subject)}";
                var sk = window.ToString(CultureInfo.InvariantCulture);
                var row = await store.GetAsync(pk, sk, ct);
                var count = row?.Deserialize<RequestRateUsage>().Count ?? 0;
                if (count >= limit.Limit) return new(false, retryAfter);
                writes.Add(StoreMutation.Put(StoreRow.Create(pk, sk, (row?.Version ?? 0) + 1,
                    new RequestRateUsage(count + 1), (window + 2) * 60), row?.Version));
            }
            try
            {
                await store.TransactAsync(writes, ct);
                return new(true, 0);
            }
            catch (StoreConflictException) when (attempt < 4)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(5 * (attempt + 1)), ct);
            }
            catch (StoreConflictException)
            {
                // Contention must never turn into an unmetered request.
                return new(false, 1);
            }
        }
        throw new InvalidOperationException("Rate-limit admission did not complete.");
    }
}
