using System.Net;
using System.Net.Http.Json;
using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
using Microsoft.Extensions.DependencyInjection;

namespace Hisaab.Api.Tests;

public sealed class BackgroundJobsTests
{
    [Fact]
    public async Task BillingFailureRetainsWorkAndSuccessfulVerificationConsumesIt()
    {
        var succeeds = false;
        var calls = 0;
        await using var factory = new ApiFactory
        {
            ProviderResponse = request =>
            {
                calls++;
                Assert.Equal("api.revenuecat.com", request.RequestUri!.Host);
                return succeeds
                    ? new(HttpStatusCode.OK) { Content = JsonContent.Create(new { subscriber = new { entitlements = new { } } }) }
                    : new(HttpStatusCode.ServiceUnavailable);
            }
        };
        var user = await ApiSession.Login(factory, "Billing user");
        await Put(factory.Store, "WORK#billing", "event", new { userId = user.UserId, id = "event" });
        var jobs = factory.Services.GetRequiredService<BackgroundJobs>();
        await Assert.ThrowsAsync<AggregateException>(() => jobs.RunAsync("billing-reconcile"));
        Assert.NotNull(await factory.Store.GetAsync("WORK#billing", "event"));
        Assert.Null(await factory.Store.GetAsync($"USER#{user.UserId}", "ENTITLEMENT#ad_free"));
        succeeds = true;
        await jobs.RunAsync("billing-reconcile");
        Assert.Null(await factory.Store.GetAsync("WORK#billing", "event"));
        Assert.NotNull(await factory.Store.GetAsync($"USER#{user.UserId}", "ENTITLEMENT#ad_free"));
        await jobs.RunAsync("billing-reconcile");
        Assert.Equal(2, calls); // Future dueAt does not repeatedly call the provider.
    }

    [Fact]
    public async Task DeletedAccountWebhookCannotRecreateItsEntitlement()
    {
        await using var factory = new ApiFactory();
        _ = factory.CreateClient();
        await Put(factory.Store, "USER#gone", "PROFILE", new UserAccount("gone", "Deleted user", null, "deleted", DateTimeOffset.UtcNow));
        await Put(factory.Store, "WORK#billing", "event", new { userId = "gone", id = "event" });
        await factory.Services.GetRequiredService<BackgroundJobs>().RunAsync("billing-reconcile");
        Assert.Null(await factory.Store.GetAsync("WORK#billing", "event"));
        Assert.Null(await factory.Store.GetAsync("USER#gone", "ENTITLEMENT#ad_free"));
    }

    [Fact]
    public async Task ReconciliationIgnoresDeletedExpensesAndDisputedPayments()
    {
        await using var factory = new ApiFactory();
        _ = factory.CreateClient();
        var expense = Expense("active", 100);
        var payment = new Settlement("partial", "g", "b", "a", 25, SettlementMethod.Cash, 1, false, "ub", DateTimeOffset.UtcNow);
        var balances = LedgerEngine.ApplySettlement(LedgerEngine.ApplyExpense(LedgerEngine.Empty(["a", "b"]), expense), payment);
        await SeedGroup(factory.Store, balances);
        await Put(factory.Store, "GROUP#g", "EXPENSE#active", expense);
        await Put(factory.Store, "GROUP#g", "EXPENSE#deleted", Expense("deleted", 200) with { DeletedAt = DateTimeOffset.UtcNow });
        await Put(factory.Store, "GROUP#g", "PAYMENT#partial", payment);
        await Put(factory.Store, "GROUP#g", "PAYMENT#disputed", payment with { Id = "disputed", AmountPaise = 10, Disputed = true });
        var jobs = factory.Services.GetRequiredService<BackgroundJobs>();
        await jobs.RunAsync("ledger-reconcile");
        Assert.NotNull(await factory.Store.GetAsync("WORK#reconcile", "g"));
        await jobs.RunAsync(null);
        Assert.Null(await factory.Store.GetAsync("WORK#reconcile", "g"));
        Assert.Equal("matched", (await factory.Store.GetAsync("RECONCILIATION", "g"))!.Data.GetProperty("status").GetString());
    }

    [Fact]
    public async Task ReconciliationReportsDriftWithoutChangingBalances()
    {
        await using var factory = new ApiFactory();
        _ = factory.CreateClient();
        await SeedGroup(factory.Store, LedgerEngine.Empty(["a", "b"]));
        await Put(factory.Store, "GROUP#g", "EXPENSE#active", Expense("active", 100));
        var jobs = factory.Services.GetRequiredService<BackgroundJobs>();
        await jobs.RunAsync("ledger-reconcile");
        await Assert.ThrowsAsync<AggregateException>(() => jobs.RunAsync(null));
        Assert.Equal("mismatch", (await factory.Store.GetAsync("RECONCILIATION", "g"))!.Data.GetProperty("status").GetString());
        Assert.NotNull(await factory.Store.GetAsync("WORK#reconcile", "g"));
        Assert.All((await factory.Store.QueryAsync("GROUP#g", "BALANCE#")).Items, row => Assert.Equal(0, row.Deserialize<Balance>().NetPaise));
    }

    [Fact]
    public async Task ReconciliationRestartsWhenGroupChangesBetweenPages()
    {
        await using var factory = new ApiFactory();
        _ = factory.CreateClient();
        var expense = Expense("first", 100);
        var balances = LedgerEngine.ApplyExpense(LedgerEngine.Empty(["a", "b"]), expense);
        await SeedGroup(factory.Store, balances);
        await Put(factory.Store, "GROUP#g", "EXPENSE#first", expense);
        var jobs = factory.Services.GetRequiredService<BackgroundJobs>();
        await jobs.RunAsync("ledger-reconcile");
        var metadata = (await factory.Store.GetAsync("GROUP#g", "META"))!;
        await factory.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(metadata.Pk, metadata.Sk, 2,
            metadata.Deserialize<Group>() with { Version = 2, Name = "Renamed" }), 1)]);
        await jobs.RunAsync(null);
        Assert.Null(await factory.Store.GetAsync("RECONCILIATION", "g"));
        await jobs.RunAsync(null);
        Assert.Equal(2, (await factory.Store.GetAsync("RECONCILIATION", "g"))!.Data.GetProperty("groupVersion").GetInt64());
    }

    [Fact]
    public async Task LargeReconciliationPersistsProgressAcrossInvocations()
    {
        await using var factory = new ApiFactory();
        _ = factory.CreateClient();
        var expenses = Enumerable.Range(0, 101).Select(i => Expense($"e{i:D3}", 100)).ToArray();
        var balances = LedgerEngine.Empty(["a", "b"]);
        foreach (var expense in expenses) balances = LedgerEngine.ApplyExpense(balances, expense);
        await SeedGroup(factory.Store, balances);
        foreach (var chunk in expenses.Chunk(90)) await factory.Store.TransactAsync(chunk.Select(expense =>
            StoreMutation.Put(StoreRow.Create("GROUP#g", $"EXPENSE#{expense.Id}", 1, expense), null)).ToArray());
        var jobs = factory.Services.GetRequiredService<BackgroundJobs>();
        await jobs.RunAsync("ledger-reconcile");
        var work = (await factory.Store.GetAsync("WORK#reconcile", "g"))!;
        Assert.Equal("expenses", work.Data.GetProperty("stage").GetString());
        Assert.False(string.IsNullOrEmpty(work.Data.GetProperty("cursor").GetString()));
        await jobs.RunAsync(null);
        await jobs.RunAsync(null);
        Assert.Equal("matched", (await factory.Store.GetAsync("RECONCILIATION", "g"))!.Data.GetProperty("status").GetString());
    }

    private static Expense Expense(string id, long amount)
    {
        SplitParticipant[] participants = [new("a"), new("b")];
        return new(id, "g", "Private expense text", amount, new DateOnly(2026, 9, 26), "a", SplitMode.Equal,
            participants, SplitEngine.Calculate(amount, SplitMode.Equal, participants).Shares, 1, null, "ua", DateTimeOffset.UtcNow);
    }
    private static async Task SeedGroup(IAtomicStore store, IReadOnlyList<Balance> balances)
    {
        await Put(store, "GROUP#g", "META", new Group("g", "Private group", GroupType.Trip, false, 1, "ua", [new("a", "ua", "A"), new("b", "ub", "B")]));
        await Put(store, "GROUPS", "g", new { groupId = "g" });
        foreach (var balance in balances) await Put(store, "GROUP#g", $"BALANCE#{balance.ParticipantId}", balance);
    }
    private static Task Put<T>(IAtomicStore store, string pk, string sk, T data)
        => store.TransactAsync([StoreMutation.Put(StoreRow.Create(pk, sk, 1, data), null)]);
}
