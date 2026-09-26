using System.Diagnostics;
using Hisaab.Api.Billing;
using Hisaab.Api.Identity;
using Hisaab.Application.Storage;
using Hisaab.Domain;

namespace Hisaab.Api.Shared;

public sealed class BackgroundJobs(IAtomicStore store, BillingService billing, AccountDeletionService deletion,
    PushService push, ILogger<BackgroundJobs> logger)
{
    public async Task RunAsync(string? job, CancellationToken ct = default)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(ct);
        budget.CancelAfter(TimeSpan.FromSeconds(45));
        var token = budget.Token;
        var elapsed = Stopwatch.StartNew();
        var failures = new List<Exception>();
        bool HasTime() => elapsed.Elapsed < TimeSpan.FromSeconds(30);

        Task Billing() => ProcessPageAsync("WORK#billing", 10, async row =>
        {
            var userId = UserId(row);
            if (await ActiveAsync(userId, token)) await billing.RefreshAsync(userId, token);
            await DeleteCurrentAsync(row, token);
        }, failures, HasTime, token);
        Task Outbox() => ProcessPageAsync("OUTBOX", 5, async row =>
        {
            await push.DeliverAsync(row, token);
            await DeleteCurrentAsync(row, token);
        }, failures, HasTime, token);
        Task Deletion() => ProcessPageAsync("WORK#deletion", 3, async row =>
        {
            await deletion.ProcessAsync(UserId(row), token);
            await DeleteCurrentAsync(row, token);
        }, failures, HasTime, token);
        Task Entitlements() => ProcessPageAsync("WORK#entitlement", 20, async row =>
        {
            var userId = UserId(row);
            if (!await ActiveAsync(userId, token)) { await DeleteCurrentAsync(row, token); return; }
            if (!row.Data.TryGetProperty("dueAt", out var due) || due.GetDateTimeOffset() <= DateTimeOffset.UtcNow)
                await billing.RefreshAsync(userId, token);
        }, failures, HasTime, token);
        async Task Reconciliation()
        {
            try { await EnqueueReconciliationPageAsync(job == "ledger-reconcile", token); }
            catch (Exception ex) when (ex is not OperationCanceledException) { failures.Add(ex); }
            if (HasTime()) await ProcessPageAsync("WORK#reconcile", 3, row => ReconcilePageAsync(row, token), failures, HasTime, token);
        }
        Func<Task>[] tasks = job switch
        {
            "outbox-dispatch" => [Outbox, Billing, Deletion, Entitlements, Reconciliation],
            "account-deletion" => [Deletion, Outbox, Billing, Entitlements, Reconciliation],
            "ledger-reconcile" => [Reconciliation, Outbox, Billing, Deletion, Entitlements],
            "billing-reconcile" => [Entitlements, Billing, Outbox, Deletion, Reconciliation],
            _ => [Billing, Outbox, Deletion, Entitlements, Reconciliation]
        };
        foreach (var task in tasks) { if (!HasTime()) break; await task(); }
        if (failures.Count != 0)
            throw new AggregateException("Background work failed; durable records remain pending for retry.", failures);
    }

    private async Task ProcessPageAsync(string partition, int limit, Func<StoreRow, Task> process,
        List<Exception> failures, Func<bool> hasTime, CancellationToken ct)
    {
        var checkpoint = await store.GetAsync("JOB#CURSOR", partition, ct);
        var cursor = checkpoint?.Deserialize<PageCheckpoint>().Cursor;
        for (var i = 0; i < limit && hasTime(); i++)
        {
            // One-row pages let even a failed provider call advance its scan checkpoint, so one
            // unavailable account/device cannot indefinitely starve the rest of the partition.
            var page = await store.QueryAsync(partition, "", 1, cursor, ct);
            if (page.Items.Count != 0)
            {
                try { await process(page.Items[0]); }
                catch (StoreConflictException) { /* Another invocation advanced the same durable work. */ }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    logger.LogWarning("Background partition {Partition} failed with {ErrorType}; work retained", partition, ex.GetType().Name);
                    failures.Add(ex);
                }
            }
            if (page.Items.Count == 0 && cursor is null) return;
            var nextCheckpoint = StoreRow.Create("JOB#CURSOR", partition, (checkpoint?.Version ?? 0) + 1, new PageCheckpoint(page.NextCursor));
            try { await store.TransactAsync([StoreMutation.Put(nextCheckpoint, checkpoint?.Version)], ct); }
            catch (StoreConflictException) { return; }
            checkpoint = nextCheckpoint;
            cursor = page.NextCursor;
            if (cursor is null) return;
        }
    }

    private async Task EnqueueReconciliationPageAsync(bool begin, CancellationToken ct)
    {
        var checkpoint = await store.GetAsync("JOB#RECONCILIATION", "GROUP_SCAN", ct);
        var state = checkpoint?.Deserialize<ScanCheckpoint>();
        if (state?.Running != true && !begin) return;
        var page = await store.QueryAsync("GROUPS", "", 25, state?.Running == true ? state.Cursor : null, ct);
        var writes = new List<StoreMutation>();
        foreach (var group in page.Items)
        {
            var id = group.Data.TryGetProperty("groupId", out var value) ? value.GetString()! : group.Sk;
            if (await store.GetAsync("WORK#reconcile", id, ct) is null)
                writes.Add(StoreMutation.Put(StoreRow.Create("WORK#reconcile", id, 1, new ReconciliationState(id, 0, "expenses", null, [])), null));
        }
        writes.Add(StoreMutation.Put(StoreRow.Create("JOB#RECONCILIATION", "GROUP_SCAN", (checkpoint?.Version ?? 0) + 1,
            new ScanCheckpoint(page.NextCursor is not null, page.NextCursor)), checkpoint?.Version));
        await store.TransactAsync(writes, ct);
    }

    private async Task ReconcilePageAsync(StoreRow work, CancellationToken ct)
    {
        var state = work.Deserialize<ReconciliationState>();
        var metadata = await store.GetAsync($"GROUP#{state.GroupId}", "META", ct);
        if (metadata is null) { await DeleteCurrentAsync(work, ct); return; }
        var group = metadata.Deserialize<Group>();
        if (state.GroupVersion != metadata.Version)
            state = new(state.GroupId, metadata.Version, "expenses", null, LedgerEngine.Empty(group.Members.Select(m => m.Id)));
        var prefix = state.Stage == "expenses" ? "EXPENSE#" : "PAYMENT#";
        var page = await store.QueryAsync(metadata.Pk, prefix, 100, state.Cursor, ct);
        var balances = state.Balances;
        try
        {
            foreach (var row in page.Items)
            {
                if (state.Stage == "expenses")
                {
                    var expense = row.Deserialize<Expense>();
                    if (expense.DeletedAt is null) balances = LedgerEngine.ApplyExpense(balances, expense);
                }
                else
                {
                    var settlement = row.Deserialize<Settlement>();
                    if (!settlement.Disputed) balances = LedgerEngine.ApplySettlement(balances, settlement);
                }
            }
        }
        catch (DomainException)
        {
            if ((await store.GetAsync(metadata.Pk, metadata.Sk, ct))?.Version != metadata.Version) return;
            logger.LogError("Ledger reconciliation found invalid source data for group {GroupId}", state.GroupId);
            throw new InvalidOperationException("Ledger source data failed reconciliation; no automatic correction was made.");
        }
        var after = await store.GetAsync(metadata.Pk, metadata.Sk, ct);
        if (after?.Version != metadata.Version) return; // Next run restarts using the current roster/revision.
        if (page.NextCursor is not null || state.Stage == "expenses")
        {
            var next = state with
            {
                Balances = balances,
                Cursor = page.NextCursor,
                Stage = page.NextCursor is null ? "payments" : state.Stage
            };
            await store.TransactAsync([
                StoreMutation.Condition(metadata.Pk, metadata.Sk, metadata.Version),
                StoreMutation.Put(StoreRow.Create(work.Pk, work.Sk, work.Version + 1, next), work.Version)
            ], ct);
            return;
        }
        var saved = await store.QueryAsync(metadata.Pk, "BALANCE#", 100, ct: ct);
        after = await store.GetAsync(metadata.Pk, metadata.Sk, ct);
        if (after?.Version != metadata.Version) return;
        var matches = Equivalent(balances, saved.Items.Select(r => r.Deserialize<Balance>()).ToArray());
        var prior = await store.GetAsync("RECONCILIATION", group.Id, ct);
        var result = StoreMutation.Put(StoreRow.Create("RECONCILIATION", group.Id, (prior?.Version ?? 0) + 1,
            new { groupId = group.Id, groupVersion = metadata.Version, checkedAt = DateTimeOffset.UtcNow, status = matches ? "matched" : "mismatch" }), prior?.Version);
        var writes = new List<StoreMutation> { StoreMutation.Condition(metadata.Pk, metadata.Sk, metadata.Version), result };
        if (matches) writes.Add(StoreMutation.Delete(work.Pk, work.Sk, work.Version));
        await store.TransactAsync(writes, ct);
        if (!matches)
        {
            logger.LogError("Ledger reconciliation mismatch for group {GroupId} at revision {Revision}", group.Id, metadata.Version);
            throw new InvalidOperationException("Ledger balances do not match source records; no automatic correction was made.");
        }
    }

    private static bool Equivalent(IReadOnlyList<Balance> expected, IReadOnlyList<Balance> actual)
        => expected.Count == actual.Count && expected.All(left => actual.Any(right =>
            left.ParticipantId == right.ParticipantId && left.NetPaise == right.NetPaise &&
            left.Counterparties.Count == right.Counterparties.Count &&
            left.Counterparties.All(pair => right.Counterparties.TryGetValue(pair.Key, out var value) && value == pair.Value)));

    private async Task<bool> ActiveAsync(string userId, CancellationToken ct)
        => (await store.GetAsync($"USER#{userId}", "PROFILE", ct))?.Deserialize<UserAccount>().Status == "active";
    private async Task DeleteCurrentAsync(StoreRow row, CancellationToken ct)
    {
        var current = await store.GetAsync(row.Pk, row.Sk, ct);
        if (current?.Version == row.Version) await store.TransactAsync([StoreMutation.Delete(row.Pk, row.Sk, row.Version)], ct);
    }
    private static string UserId(StoreRow row) => row.Data.GetProperty("userId").GetString()
        ?? throw new InvalidDataException("Background work is missing its account ID.");
}
