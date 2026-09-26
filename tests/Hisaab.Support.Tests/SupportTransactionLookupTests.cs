using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;
using Hisaab.Support;

namespace Hisaab.Support.Tests;

public sealed class SupportTransactionLookupTests
{
    [Fact]
    public async Task ExactTransactionAndStoreResolveRecordedAccountWithoutMutation()
    {
        var store = new LocalAtomicStore();
        var userId = Guid.NewGuid().ToString();
        var key = $"STORE#APP_STORE#{Ids.Hash("tx-current")}";
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create(key, "OWNER", 1,
            new { userId, provider = "APP_STORE", transactionId = "tx-current", eventId = "provider-event" }), null)]);
        var lookup = new SupportTransactionLookup(store);
        var result = await lookup.FindAsync("app_store", "tx-current");
        Assert.Equal(userId, result!.RecordedOwnerUserId);
        Assert.Equal("APP_STORE", result.Store);
        Assert.Equal("provider-event", result.EventId);
        Assert.Null(await lookup.FindAsync("PLAY_STORE", "tx-current"));
        Assert.Null(await lookup.FindAsync("APP_STORE", "different-transaction"));
        Assert.Null(await store.GetAsync($"USER#{userId}", "ENTITLEMENT#ad_free"));
        Assert.Equal(1, (await store.GetAsync(key, "OWNER"))!.Version);
    }

    [Fact]
    public async Task OriginalTransactionReferenceUsesTheSameIndexContract()
    {
        var store = new LocalAtomicStore();
        var userId = Guid.NewGuid().ToString();
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create($"STORE#PLAY_STORE#{Ids.Hash("GPA.original")}", "OWNER", 1,
            new { userId, provider = "PLAY_STORE", transactionId = "GPA.original", eventId = "renewal" }), null)]);
        Assert.Equal(userId, (await new SupportTransactionLookup(store).FindAsync("PLAY_STORE", "GPA.original"))!.RecordedOwnerUserId);
    }

    [Theory]
    [InlineData("UNKNOWN_STORE", "transaction")]
    [InlineData("APP_STORE", "")]
    [InlineData("APP_STORE", "  ")]
    [InlineData("APP_STORE", "transaction\nforged-output")]
    public async Task UnsupportedStoreAndInvalidTransactionAreRejected(string provider, string transaction)
    {
        await Assert.ThrowsAsync<ArgumentException>(() => new SupportTransactionLookup(new LocalAtomicStore()).FindAsync(provider, transaction));
    }

    [Fact]
    public async Task CorruptAttributionCannotResolveAnArbitraryPartition()
    {
        var store = new LocalAtomicStore();
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create($"STORE#APP_STORE#{Ids.Hash("transaction")}", "OWNER", 1,
            new { userId = "not-an-account-id", provider = "APP_STORE" }), null)]);
        await Assert.ThrowsAsync<InvalidDataException>(() => new SupportTransactionLookup(store).FindAsync("APP_STORE", "transaction"));
    }
}
