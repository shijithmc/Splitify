using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;

namespace Hisaab.Infrastructure.Tests;

public sealed class LocalAtomicStoreTests
{
    [Fact]
    public async Task FailedVersionRollsBackEntireTransaction()
    {
        var store = new LocalAtomicStore();
        await store.TransactAsync([Put("balance", 1), Put("expense", 1)]);
        await Assert.ThrowsAsync<StoreConflictException>(() => store.TransactAsync([
            Put("balance", 2, 1), Put("expense", 3, 2)]));
        Assert.Equal(1, (await store.GetAsync("group", "balance"))!.Version);
        Assert.Equal(1, (await store.GetAsync("group", "expense"))!.Version);
    }

    [Fact]
    public async Task IndependentAccountConditionPreventsFrozenActorFromWriting()
    {
        var store = new LocalAtomicStore();
        await store.TransactAsync([Put("account", 1), Put("balance", 1)]);
        await store.TransactAsync([Put("account", 2, 1)]);
        await Assert.ThrowsAsync<StoreConflictException>(() => store.TransactAsync([
            StoreMutation.Condition("group", "account", 1), Put("balance", 2, 1)]));
        Assert.Equal(1, (await store.GetAsync("group", "balance"))!.Version);
    }

    [Fact]
    public async Task ConditionsCanRequireAbsenceAndDeleteRequiresVersion()
    {
        var store = new LocalAtomicStore();
        await store.TransactAsync([StoreMutation.Condition("group", "absent", null), Put("expense", 1)]);
        await Assert.ThrowsAsync<StoreConflictException>(() => store.TransactAsync([
            StoreMutation.Delete("group", "expense", 2)]));
        await store.TransactAsync([StoreMutation.Delete("group", "expense", 1)]);
        Assert.Null(await store.GetAsync("group", "expense"));
    }

    [Fact]
    public async Task FiftyConcurrentWritersHaveExactlyOneWinner()
    {
        var store = new LocalAtomicStore();
        await store.TransactAsync([Put("balance", 1)]);
        var attempts = Enumerable.Range(0, 50).Select(async _ =>
        {
            try { await store.TransactAsync([Put("balance", 2, 1), Put("command-idempotency-key", 1)]); return true; }
            catch (StoreConflictException) { return false; }
        });
        Assert.Single(await Task.WhenAll(attempts), won => won);
        Assert.Equal(2, (await store.GetAsync("group", "balance"))!.Version);
        Assert.Equal(1, (await store.GetAsync("group", "command-idempotency-key"))!.Version);
    }

    [Fact]
    public async Task AtomicFileSurvivesRestartAndSerializesInstances()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hisaab-store-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "data.json");
        try
        {
            var first = new LocalAtomicStore(path);
            var second = new LocalAtomicStore(path);
            await first.TransactAsync([Put("balance", 1), Put("command", 1)]);
            await second.TransactAsync([Put("balance", 2, 1)]);
            Assert.Equal(2, (await first.GetAsync("group", "balance"))!.Version);
            var reopened = new LocalAtomicStore(path);
            await Assert.ThrowsAsync<StoreConflictException>(() => reopened.TransactAsync([Put("command", 1)]));
            Assert.Equal(2, (await reopened.GetAsync("group", "balance"))!.Version);
            Assert.Single(Directory.GetFiles(directory));
            if (!OperatingSystem.IsWindows())
                Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(path));
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public async Task CorruptFileIsNeverReplacedWithAnEmptyStore()
    {
        var path = Path.Combine(Path.GetTempPath(), "hisaab-corrupt-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            await File.WriteAllTextAsync(path, "corrupt");
            await Assert.ThrowsAsync<System.Text.Json.JsonException>(() => new LocalAtomicStore(path).TransactAsync([Put("test", 1)]));
            Assert.Equal("corrupt", await File.ReadAllTextAsync(path));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public async Task PrefixPaginationIsStableAndCursorBoundToQuery()
    {
        var store = new LocalAtomicStore();
        await store.TransactAsync(Enumerable.Range(0, 60).Select(i => Put($"expense#{i:D4}", 1)).ToArray());
        await store.TransactAsync([Put("payment#1", 1)]);
        var first = await store.QueryAsync("group", "expense#", 25);
        var second = await store.QueryAsync("group", "expense#", 25, first.NextCursor);
        var third = await store.QueryAsync("group", "expense#", 25, second.NextCursor);
        Assert.Equal(25, first.Items.Count);
        Assert.Equal("expense#0025", second.Items[0].Sk);
        Assert.Equal(10, third.Items.Count);
        Assert.Null(third.NextCursor);
        await Assert.ThrowsAsync<StoreValidationException>(() => store.QueryAsync("other", "expense#", 25, first.NextCursor));
        await Assert.ThrowsAsync<StoreValidationException>(() => store.QueryAsync("group", "payment#", 25, first.NextCursor));
        await Assert.ThrowsAsync<StoreValidationException>(() => store.QueryAsync("group", "expense#", 25, "invalid"));
    }

    [Fact]
    public async Task HundredDistinctActionsSucceedButHundredAndOneFail()
    {
        var store = new LocalAtomicStore();
        await store.TransactAsync(Enumerable.Range(0, 100).Select(i => Put(i.ToString(), 1)).ToArray());
        Assert.Equal(100, (await store.QueryAsync("group", "")).Items.Count);
        await Assert.ThrowsAsync<StoreValidationException>(() => store.TransactAsync(
            Enumerable.Range(0, 101).Select(i => Put($"new-{i}", 1)).ToArray()));
        Assert.Null(await store.GetAsync("group", "new-0"));
    }

    [Fact]
    public async Task DuplicateConditionAndWriteToSameKeyIsRejected()
    {
        var store = new LocalAtomicStore();
        await Assert.ThrowsAsync<StoreValidationException>(() => store.TransactAsync([
            StoreMutation.Condition("group", "expense", null), Put("expense", 1)]));
        Assert.Null(await store.GetAsync("group", "expense"));
    }

    [Fact]
    public async Task ItemAndTransactionByteLimitsAreEnforcedBeforeAnyWrite()
    {
        var store = new LocalAtomicStore();
        await Assert.ThrowsAsync<StoreValidationException>(() => store.TransactAsync([
            StoreMutation.Put(StoreRow.Create("group", "huge", 1, new { Text = new string('x', 400 * 1024) }), null)]));
        await Assert.ThrowsAsync<StoreValidationException>(() => store.TransactAsync(
            Enumerable.Range(0, 11).Select(i => StoreMutation.Put(
                StoreRow.Create("group", i.ToString(), 1, new { Text = new string('x', 390 * 1024) }), null)).ToArray()));
        Assert.Empty((await store.QueryAsync("group", "")).Items);
    }

    [Fact]
    public async Task DeletesAlsoCountExistingItemsAgainstTransactionSizeLimit()
    {
        var store = new LocalAtomicStore();
        for (var i = 0; i < 11; i++)
            await store.TransactAsync([StoreMutation.Put(StoreRow.Create("group", i.ToString(), 1,
                new { Text = new string('x', 390 * 1024) }), null)]);
        await Assert.ThrowsAsync<StoreValidationException>(() => store.TransactAsync(
            Enumerable.Range(0, 11).Select(i => StoreMutation.Delete("group", i.ToString(), 1)).ToArray()));
        Assert.Equal(11, (await store.QueryAsync("group", "")).Items.Count);
    }

    [Theory]
    [InlineData(0, null)]
    [InlineData(2, null)]
    [InlineData(2, 0L)]
    [InlineData(1, 1L)]
    public async Task VersionsMustAdvanceMonotonically(long next, long? expected)
    {
        await Assert.ThrowsAsync<StoreValidationException>(() => new LocalAtomicStore().TransactAsync([Put("expense", next, expected)]));
    }

    [Fact]
    public async Task CancellationBeforeTransactionDoesNotWrite()
    {
        var store = new LocalAtomicStore();
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.TransactAsync([Put("expense", 1)], cancelled.Token));
        Assert.Null(await store.GetAsync("group", "expense"));
    }

    [Fact]
    public void RowsRoundTripCamelCaseAndEnumStrings()
    {
        var row = StoreRow.Create("group", "one", 1, new Payload(12, DayOfWeek.Friday));
        Assert.Equal(12, row.Data.GetProperty("netPaise").GetInt64());
        Assert.Equal("Friday", row.Data.GetProperty("day").GetString());
        Assert.Equal(new Payload(12, DayOfWeek.Friday), row.Deserialize<Payload>());
    }

    private static StoreMutation Put(string sk, long version, long? expected = null)
        => StoreMutation.Put(StoreRow.Create("group", sk, version, new { AmountPaise = 100L }), expected);
    private sealed record Payload(long NetPaise, DayOfWeek Day);
}
