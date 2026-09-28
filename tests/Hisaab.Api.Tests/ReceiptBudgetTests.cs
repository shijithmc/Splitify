using System.Globalization;
using Hisaab.Api.Billing;
using Hisaab.Api.Identity;
using Hisaab.Api.Receipts;
using Hisaab.Application.Storage;
using Hisaab.Domain;

namespace Hisaab.Api.Tests;

public sealed class ReceiptBudgetTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExactMonthlyCeilingIsAllowedAndNextAttemptIsBlockedForEveryPlan(bool paid)
    {
        var c = await ReceiptTestContext.Create();
        c.Config["Hisaab:Receipts:MonthlyBudgetUsd"] = "0.02";
        if (paid) await MakeSubscriberAsync(c);

        await c.Store.TransactAsync(await c.Budget.AdmitAsync(paid, default));
        Assert.True((await c.Quotas.AllowanceAsync(c.Actor.User.Id, default)).ScanAvailable);
        await c.Store.TransactAsync(await c.Budget.AdmitAsync(paid, default));

        var exhausted = await c.Quotas.AllowanceAsync(c.Actor.User.Id, default);
        Assert.False(exhausted.ScanAvailable);
        Assert.Equal("scan_paused", exhausted.Reason);
        Assert.Equal(paid ? 100 : 5, exhausted.Cap);
        var error = await Assert.ThrowsAsync<DomainException>(() => c.Budget.AdmitAsync(paid, default));
        Assert.Equal("scan_paused", error.Code);
        var budget = await BudgetAsync(c);
        Assert.Equal(20_000, budget.ReservedMicrousd);
        Assert.Equal(2, budget.Attempts);
    }

    [Fact]
    public async Task SeparateInstancesCannotConcurrentlyReserveTheLastBudgetSlotTwice()
    {
        var c = await ReceiptTestContext.Create();
        c.Config["Hisaab:Receipts:MonthlyBudgetUsd"] = "0.01";
        // Both instances read the same version before either conditional write commits.
        var first = await new ReceiptBudgetService(c.Store, c.Config).AdmitAsync(false, default);
        var second = await new ReceiptBudgetService(c.Store, c.Config).AdmitAsync(true, default);
        async Task<bool> CommitAsync(IReadOnlyList<StoreMutation> writes)
        {
            try { await c.Store.TransactAsync(writes); return true; }
            catch (StoreConflictException) { return false; }
        }

        var committed = await Task.WhenAll(CommitAsync(first), CommitAsync(second));
        Assert.Equal(1, committed.Count(value => value));
        var budget = await BudgetAsync(c);
        Assert.Equal(10_000, budget.ReservedMicrousd);
        Assert.Equal(1, budget.Attempts);
        await Assert.ThrowsAsync<DomainException>(() => new ReceiptBudgetService(c.Store, c.Config).AdmitAsync(true, default));
    }

    [Fact]
    public async Task WorkersForDifferentAccountsCannotCallProviderBeyondSharedBudget()
    {
        var c = await ReceiptTestContext.Create();
        c.Config["Hisaab:Receipts:MonthlyBudgetUsd"] = "0.01";
        await MakeSubscriberAsync(c);
        var paidReceipt = await c.CreateReceipt();
        var freeReceipt = await CreateReceiptAsync(c, c.Other);
        var release = new TaskCompletionSource<ReceiptExtraction>(TaskCreationOptions.RunContinuationsAsynchronously);
        c.Extractor.Handler = () => release.Task;

        var calls = new[] { c.Worker.ProcessAsync(paidReceipt), c.Worker.ProcessAsync(freeReceipt) };
        for (var attempt = 0; attempt < 100 && c.Extractor.Calls == 0; attempt++) await Task.Delay(10);
        var providerCalls = c.Extractor.Calls;
        release.SetResult(new("not_bill", null, "test", "1", "1", []));
        await Task.WhenAll(calls);
        Assert.Equal(1, providerCalls);
        // A losing conditional transaction stays queued; redelivery must still stop it.
        await c.Worker.ProcessAsync(paidReceipt);
        await c.Worker.ProcessAsync(freeReceipt);
        Assert.Equal(1, c.Extractor.Calls);
        Assert.Equal(1, (await BudgetAsync(c)).Attempts);
        Assert.False((await c.Quotas.AllowanceAsync(c.Actor.User.Id, default)).ScanAvailable);
        Assert.False((await c.Quotas.AllowanceAsync(c.Other.User.Id, default)).ScanAvailable);
    }

    [Fact]
    public async Task FailedAttemptKeepsItsBudgetChargeAndCannotRetryPastCeiling()
    {
        var c = await ReceiptTestContext.Create();
        c.Config["Hisaab:Receipts:MonthlyBudgetUsd"] = "0.01";
        await MakeSubscriberAsync(c);
        c.Extractor.Handler = () => throw new ReceiptProviderException("receipt_provider_unavailable", true);
        var id = await c.CreateReceipt();
        await c.Worker.ProcessAsync(id);
        Assert.Equal("queued", (await c.Receipt(id)).State);

        var work = (await c.Store.GetAsync("WORK#receipt-scan", id))!;
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(work.Pk, work.Sk, work.Version + 1,
            new ReceiptWork(id, DateTimeOffset.UtcNow)), work.Version)]);
        await c.Worker.ProcessAsync(id);

        var receipt = await c.Receipt(id);
        Assert.Equal("failed", receipt.State);
        Assert.Equal("scan_paused", receipt.ErrorCode);
        Assert.Equal(1, c.Extractor.Calls);
        Assert.Equal(10_000, (await BudgetAsync(c)).ReservedMicrousd);
        Assert.Equal(0, (await c.Quotas.AllowanceAsync(c.Actor.User.Id, default)).Reserved);
    }

    [Fact]
    public async Task FreePauseDoesNotChangePaidAllowanceBelowTheHardCeiling()
    {
        var c = await ReceiptTestContext.Create();
        await MakeSubscriberAsync(c);
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create("OPERATIONS", "RECEIPTS", 1,
            new ReceiptRuntimeControl(PauseFree: true)), null)]);

        Assert.True((await c.Quotas.AllowanceAsync(c.Actor.User.Id, default)).ScanAvailable);
        Assert.False((await c.Quotas.AllowanceAsync(c.Other.User.Id, default)).ScanAvailable);
        await c.Store.TransactAsync(await c.Budget.AdmitAsync(true, default));
        await Assert.ThrowsAsync<DomainException>(() => c.Budget.AdmitAsync(false, default));
    }

    private static async Task MakeSubscriberAsync(ReceiptTestContext c) =>
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"USER#{c.Actor.User.Id}", "ENTITLEMENT#ad_free", 1,
            new Entitlement(true, "active", DateTimeOffset.UtcNow.AddDays(30), VerifiedAt: DateTimeOffset.UtcNow)), null)]);

    private static async Task<ReceiptBudget> BudgetAsync(ReceiptTestContext c) =>
        (await c.Store.GetAsync("RECEIPT_BUDGET", DateTimeOffset.UtcNow.ToString("yyyyMM", CultureInfo.InvariantCulture)))!.Deserialize<ReceiptBudget>();

    private static async Task<string> CreateReceiptAsync(ReceiptTestContext c, Actor actor)
    {
        await c.Service.ConsentAsync(actor, Guid.NewGuid().ToString(), new(ReceiptQuotaService.ConsentVersion, true), default);
        var id = Guid.NewGuid().ToString();
        await c.Service.CreateAsync(actor, Guid.NewGuid().ToString(), c.GroupId,
            new(id, true, [new(Guid.NewGuid().ToString(), "image/jpeg", 10, new string('a', 64))]), default);
        await c.Service.CompleteAsync(actor, Guid.NewGuid().ToString(), id, new(1), default);
        await c.Worker.ProcessAsync(id);
        return id;
    }
}
