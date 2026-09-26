using System.Net;
using System.Net.Http.Headers;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Identity;

public sealed class AccountDeletionService(IAtomicStore store, IdentityService identity, AppleTokens apple, IHttpClientFactory clients, IConfiguration config, IHostEnvironment environment)
{
    public async Task<object> RequestAsync(Actor actor, bool confirm, CancellationToken ct = default)
    {
        IdentityService.Recent(actor);
        if (!confirm) throw new DomainException(422, "confirmation_required", "Confirm deletion after reviewing your open balances and store subscription. Deletion does not cancel store billing.");
        var user = actor.User with { Status = "deleting" };
        await store.TransactAsync([
            StoreMutation.Put(StoreRow.Create($"USER#{user.Id}","PROFILE",actor.AccountVersion+1,user),actor.AccountVersion),
            StoreMutation.Condition($"SESSION#{actor.SessionHash}","META",actor.SessionVersion),
            StoreMutation.Put(StoreRow.Create("WORK#deletion",user.Id,1,new AccountDeletionState(user.Id,DateTimeOffset.UtcNow,DateTimeOffset.UtcNow.AddDays(30))),null)
        ], ct);
        if (!environment.IsDevelopment() && !environment.IsEnvironment("Testing")) return new { status = "deleting", message = "Your account is disabled and deletion is queued. Store subscriptions must be managed separately." };
        // Local tests can complete immediately; production always uses the durable worker.
        try { await ProcessAsync(user.Id, ct); }
        catch (Exception ex) when (ex is DomainException or HttpRequestException or StoreConflictException or TaskCanceledException) { return new { status = "deleting", message = "Your account is disabled. Data deletion is queued; store subscriptions must be managed separately." }; }
        return new { status = "deleted", message = "Account deleted. Shared balances are retained under Deleted user. Store subscriptions are managed separately." };
    }
    public async Task ProcessAsync(string userId, CancellationToken ct = default)
    {
        var pk = $"USER#{userId}"; var profile = await store.GetAsync(pk, "PROFILE", ct);
        if (profile is null) return;
        var user = profile.Deserialize<UserAccount>();
        if (user.Status == "active") throw new InvalidOperationException("Account must be frozen before deletion.");
        var job = await store.GetAsync("WORK#deletion", userId, ct);
        if (job is null) return;
        var state = job.Deserialize<AccountDeletionState>();
        var identities = await AllAsync(pk, "IDENTITY#", ct);
        foreach (var pointer in identities)
        {
            var key = pointer.Data.GetProperty("key").GetString()!; var row = await store.GetAsync(key, "OWNER", ct);
            if (row is null) continue; var provider = row.Deserialize<ProviderIdentity>();
            if (provider.UserId != userId) continue;
            if (provider.Provider == "apple" && !(state.RevokedProviders ?? []).Contains(key))
            {
                await apple.RevokeAsync(provider, ct);
                state = state with { RevokedProviders = [.. state.RevokedProviders ?? [], key] };
                var next = StoreRow.Create(job.Pk, job.Sk, job.Version + 1, state);
                await store.TransactAsync([StoreMutation.Put(next, job.Version)], ct); job = next;
            }
        }
        var revenueCatKey = config["Hisaab:RevenueCat:SecretKey"];
        if (!string.IsNullOrEmpty(revenueCatKey) && !state.RevenueCatDeleted)
        {
            using var request = new HttpRequestMessage(HttpMethod.Delete, $"https://api.revenuecat.com/v1/subscribers/{Uri.EscapeDataString(userId)}"); request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", revenueCatKey);
            using var response = await clients.CreateClient().SendAsync(request, ct);
            if (!response.IsSuccessStatusCode && response.StatusCode != HttpStatusCode.NotFound) throw new DomainException(503, "processor_deletion_pending", "Account processor deletion is pending.");
            state = state with { RevenueCatDeleted = true };
            var next = StoreRow.Create(job.Pk, job.Sk, job.Version + 1, state);
            await store.TransactAsync([StoreMutation.Put(next, job.Version)], ct); job = next;
        }
        // Remove each membership edge only in the transaction that anonymizes its roster.
        // A timed-out worker therefore resumes at remaining groups instead of rescanning all history.
        while (true)
        {
            var page = await store.QueryAsync(pk, "GROUP#", 25, ct: ct);
            if (page.Items.Count == 0) break;
            foreach (var edge in page.Items)
            {
                for (var attempt = 0; attempt < 5; attempt++)
                {
                    var currentEdge = await store.GetAsync(edge.Pk, edge.Sk, ct); if (currentEdge is null) break;
                    var row = await store.GetAsync($"GROUP#{edge.Sk[6..]}", "META", ct);
                    var writes = new List<StoreMutation> { StoreMutation.Delete(edge.Pk, edge.Sk, currentEdge.Version) };
                    if (row is not null)
                    {
                        var group = row.Deserialize<Group>();
                        if (group.Members.Any(m => m.UserId == userId))
                        {
                            var anonymized = group with { Version = group.Version + 1, Members = group.Members.Select(m => m.UserId == userId ? m with { UserId = null, DisplayName = "Deleted user", IsDeleted = true, IsPlaceholder = false, HasLeft = true } : m).ToArray() };
                            writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, row.Version + 1, anonymized), row.Version));
                        }
                    }
                    try { await store.TransactAsync(writes, ct); break; }
                    catch (StoreConflictException) when (attempt < 4) { }
                }
            }
        }
        foreach (var pointer in identities)
        {
            var key = pointer.Data.GetProperty("key").GetString()!; var row = await store.GetAsync(key, "OWNER", ct); if (row is null) continue;
            var provider = row.Deserialize<ProviderIdentity>(); if (provider.UserId != userId) continue;
            await RemoveContactAsync(provider.Email, userId, ct); await store.TransactAsync([StoreMutation.Delete(row.Pk, row.Sk, row.Version)], ct);
        }
        await RemoveContactAsync(user.Email, userId, ct);
        while (true)
        {
            var page = await store.QueryAsync(pk, "SESSION#", 25, ct: ct); if (page.Items.Count == 0) break;
            foreach (var index in page.Items)
            {
                var writes = new List<StoreMutation> { StoreMutation.Delete(index.Pk, index.Sk, index.Version) };
                var session = await store.GetAsync(index.Sk, "META", ct);
                if (session is not null)
                {
                    writes.Add(StoreMutation.Delete(session.Pk, session.Sk, session.Version));
                    var refresh = await store.GetAsync($"REFRESH#{session.Deserialize<SessionRecord>().RefreshHash}", "META", ct);
                    if (refresh is not null) writes.Add(StoreMutation.Delete(refresh.Pk, refresh.Sk, refresh.Version));
                }
                await store.TransactAsync(writes, ct);
            }
        }
        while (true)
        {
            var page = await store.QueryAsync(pk, "", 90, ct: ct);
            var rows = page.Items.Where(r => r.Sk != "PROFILE").ToArray(); if (rows.Length == 0) break;
            await store.TransactAsync(rows.Select(r => StoreMutation.Delete(r.Pk, r.Sk, r.Version)).ToArray(), ct);
        }
        var verify = await store.GetAsync("WORK#entitlement", userId, ct); if (verify is not null) await store.TransactAsync([StoreMutation.Delete(verify.Pk, verify.Sk, verify.Version)], ct);
        profile = await store.GetAsync(pk, "PROFILE", ct) ?? throw new InvalidOperationException("Missing deletion tombstone.");
        var tombstone = new UserAccount(user.Id, "Deleted user", null, "deleted", user.CreatedAt);
        var final = new List<StoreMutation> { StoreMutation.Put(StoreRow.Create(pk, "PROFILE", profile.Version + 1, tombstone), profile.Version) };
        job = await store.GetAsync("WORK#deletion", userId, ct); if (job is not null) final.Add(StoreMutation.Delete(job.Pk, job.Sk, job.Version));
        await store.TransactAsync(final, ct);
    }
    private async Task RemoveContactAsync(string? email, string userId, CancellationToken ct)
    {
        if (email is null) return; var row = await store.GetAsync(identity.ContactKey(email), $"ACCOUNT#{userId}", ct); if (row is not null) await store.TransactAsync([StoreMutation.Delete(row.Pk, row.Sk, row.Version)], ct);
    }
    private async Task<List<StoreRow>> AllAsync(string pk, string prefix, CancellationToken ct)
    {
        var rows = new List<StoreRow>(); string? cursor = null; do { var page = await store.QueryAsync(pk, prefix, 100, cursor, ct); rows.AddRange(page.Items); cursor = page.NextCursor; } while (cursor is not null); return rows;
    }
}
