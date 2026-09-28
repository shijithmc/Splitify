using System.Text.Json;
using Hisaab.Api.Billing;
using Hisaab.Api.Receipts;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Tests;
public sealed class ReceiptOrchestrationTests
{
    [Fact]
    public async Task SuccessfulScanCountsExactlyOnceAndNeverCreatesExpense()
    {
        var c=await ReceiptTestContext.Create();var id=await c.CreateReceipt();await Task.WhenAll(c.Worker.ProcessAsync(id),c.Worker.ProcessAsync(id));await c.Worker.ProcessAsync(id);
        var receipt=await c.Receipt(id);Assert.Equal("ready",receipt.State);Assert.Equal(1,c.Extractor.Calls);Assert.True(receipt.Counted);
        var allowance=await c.Quotas.AllowanceAsync(c.Actor.User.Id,default);Assert.Equal(1,allowance.Used);Assert.Equal(0,allowance.Reserved);
        Assert.Empty((await c.Store.QueryAsync($"GROUP#{c.GroupId}","EXPENSE#")).Items);
    }
    [Fact]
    public async Task ManualAttachmentDoesNotNeedProviderOrConsumeAllowance()
    {
        var c=await ReceiptTestContext.Create();var id=await c.CreateReceipt(false);Assert.Equal("manual_ready",(await c.Receipt(id)).State);Assert.Equal(0,c.Extractor.Calls);Assert.Equal(0,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Used);
    }
    [Fact]
    public async Task ConcurrentSixthFreeScanCannotStartProvider()
    {
        var c=await ReceiptTestContext.Create();var ids=new List<string>();for(var i=0;i<6;i++)ids.Add(await c.CreateReceipt());
        var release=new TaskCompletionSource<ReceiptExtraction>();c.Extractor.Handler=()=>release.Task;
        var calls=ids.Select(id=>c.Worker.ProcessAsync(id)).ToArray();
        for(var n=0;n<100&&c.Extractor.Calls<5;n++)await Task.Delay(10);
        Assert.Equal(5,c.Extractor.Calls);Assert.Equal(5,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Reserved);
        release.SetResult(new("bill",JsonSerializer.SerializeToElement(new{merchant="Cafe"}),"test","1","1",[]));await Task.WhenAll(calls);
        Assert.Equal(5,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Used);
        // Conditional losers remain durable queued work; a later worker rejects the sixth.
        foreach(var id in ids)await c.Worker.ProcessAsync(id);
        Assert.Equal(5,c.Extractor.Calls);
    }
    [Fact]
    public async Task NonBillReleasesQuotaAndRevokesImagesBeforePurge()
    {
        var c=await ReceiptTestContext.Create();c.Extractor.Handler=()=>Task.FromResult(new ReceiptExtraction("not_bill",null,"test","1","1",[]));var id=await c.CreateReceipt();await c.Worker.ProcessAsync(id);
        var receipt=await c.Receipt(id);Assert.Equal("not_bill",receipt.State);Assert.True(receipt.ImagesRemoved);Assert.True(receipt.PurgeAt<=DateTimeOffset.UtcNow.AddHours(24));Assert.Equal(0,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Used);
        await Assert.ThrowsAsync<DomainException>(()=>c.Service.TicketAsync(c.Actor,id,default));
    }
    [Fact]
    public async Task LateProviderResultCannotOverwriteCancelledReceiptOrConsumeQuota()
    {
        var c=await ReceiptTestContext.Create();var id=await c.CreateReceipt();var result=new TaskCompletionSource<ReceiptExtraction>();c.Extractor.Handler=()=>result.Task;var running=c.Worker.ProcessAsync(id);
        for(var i=0;i<100&&c.Extractor.Calls==0;i++)await Task.Delay(10);
        var row=(await c.Store.GetAsync($"RECEIPT#{id}","META"))!;await c.Lifecycle.CancelAsync(row,default);
        result.SetResult(new("bill",JsonSerializer.SerializeToElement(new{}),"test","1","1",[]));await running;
        Assert.Equal("cancelled",(await c.Receipt(id)).State);var quota=await c.Quotas.AllowanceAsync(c.Actor.User.Id,default);Assert.Equal(0,quota.Used);Assert.Equal(0,quota.Reserved);
    }
    [Fact]
    public async Task CopiedMediaTicketAndDepartedMemberCannotRead()
    {
        var c=await ReceiptTestContext.Create();var id=await c.CreateReceipt(false);var receipt=await c.Receipt(id);var expenseId=Guid.NewGuid().ToString();await c.PutReceipt(receipt with{ExpenseId=expenseId,State="attached"});
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"GROUP#{c.GroupId}",$"EXPENSE#{expenseId}",1,new Expense(expenseId,c.GroupId,"Bill",100,DateOnly.FromDateTime(DateTime.UtcNow),"alice",SplitMode.Equal,[new("alice"),new("bob")],new Dictionary<string,long>{{"alice",50},{"bob",50}},1,null,c.Actor.User.Id,DateTimeOffset.UtcNow)),null)]);
        var ticket=JsonSerializer.SerializeToElement(await c.Service.TicketAsync(c.Actor,id,default)).GetProperty("ticket").GetString()!;
        await Assert.ThrowsAsync<DomainException>(()=>c.Service.MediaAsync(c.Other,id,receipt.Media[0].Id,ticket,false,0,10,default));
        Assert.Equal(10,(await c.Service.MediaAsync(c.Actor,id,receipt.Media[0].Id,ticket,false,0,10,default)).Bytes.Length);
        var groupRow=(await c.Store.GetAsync($"GROUP#{c.GroupId}","META"))!;var group=groupRow.Deserialize<Group>();await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(groupRow.Pk,groupRow.Sk,2,group with{Version=2,Members=group.Members.Select(m=>m.UserId==c.Actor.User.Id?m with{HasLeft=true}:m).ToArray()}),1)]);
        await Assert.ThrowsAsync<DomainException>(()=>c.Service.MediaAsync(c.Actor,id,receipt.Media[0].Id,ticket,false,0,10,default));
    }
    [Fact]
    public async Task AdOnlySupportGrantDoesNotUnlockPaidScans()
    {
        var c=await ReceiptTestContext.Create();await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"USER#{c.Actor.User.Id}","SUPPORT_GRANT",1,new Entitlement(true,"support_grant",DateTimeOffset.UtcNow.AddDays(1),VerifiedAt:DateTimeOffset.UtcNow)),null)]);
        Assert.Equal(5,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Cap);
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"USER#{c.Actor.User.Id}","ENTITLEMENT#ad_free",1,new Entitlement(true,"grace",DateTimeOffset.UtcNow.AddDays(1),VerifiedAt:DateTimeOffset.UtcNow)),null)]);
        Assert.Equal(100,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Cap);
    }
    [Fact]
    public void ScanMonthUsesIndiaMidnight()
    {
        var before=DateTimeOffset.Parse("2026-09-30T18:29:59Z");var after=before.AddSeconds(1);Assert.Equal("202609",ReceiptQuotaService.Month(before));Assert.Equal("202610",ReceiptQuotaService.Month(after));Assert.Equal(after,ReceiptQuotaService.Reset(before));
    }
    [Fact]
    public async Task AutomaticRetryAndOneUserRetryCannotExceedThreeProviderCalls()
    {
        var c=await ReceiptTestContext.Create();c.Extractor.Handler=()=>throw new ReceiptProviderException("receipt_provider_unavailable",true);var id=await c.CreateReceipt();await c.Worker.ProcessAsync(id);
        Assert.Equal("queued",(await c.Receipt(id)).State);Assert.Equal(1,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Reserved);
        var work=(await c.Store.GetAsync("WORK#receipt-scan",id))!;await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(work.Pk,work.Sk,work.Version+1,new ReceiptWork(id,DateTimeOffset.UtcNow)),work.Version)]);await c.Worker.ProcessAsync(id);
        var failed=await c.Receipt(id);Assert.Equal("failed",failed.State);Assert.Equal(0,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Reserved);
        await c.Service.RetryAsync(c.Actor,Guid.NewGuid().ToString(),id,new(failed.Version),default);await c.Worker.ProcessAsync(id);failed=await c.Receipt(id);
        Assert.Equal(3,c.Extractor.Calls);Assert.Equal("failed",failed.State);Assert.Equal(0,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Used);
        Assert.Equal("receipt_retry_unavailable",(await Assert.ThrowsAsync<DomainException>(()=>c.Service.RetryAsync(c.Actor,Guid.NewGuid().ToString(),id,new(failed.Version),default))).Code);
    }

    [Fact]
    public async Task UploadAdmissionBoundsManualDraftsAndReservesDeclaredBytes()
    {
        var c=await ReceiptTestContext.Create();c.Config["Hisaab:Receipts:MaxPendingUploadBytes"]="15";
        var id=await c.CreateReceipt(false);var second=Guid.NewGuid().ToString();
        var error=await Assert.ThrowsAsync<DomainException>(()=>c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),c.GroupId,new(second,false,[new(Guid.NewGuid().ToString(),"image/jpeg",10,new string('a',64))]),default));
        Assert.Equal("receipt_upload_storage_limit",error.Code);Assert.Null(await c.Store.GetAsync($"RECEIPT#{second}","META"));
        var admitted=(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_UPLOAD_ADMISSION"))!.Deserialize<ReceiptUploadUsage>();Assert.Equal(10,Assert.Single(admitted.Reservations).Bytes);Assert.True(admitted.Reservations[0].ExpiresAt>DateTimeOffset.UtcNow.AddDays(6));
        _=id;
    }

    [Fact]
    public async Task UploadSessionsHaveIndependentRateLimitAndExpiredWorkCannotCallProvider()
    {
        var c=await ReceiptTestContext.Create();var id=await c.CreateReceipt();var row=(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_UPLOAD_ADMISSION"))!;var usage=row.Deserialize<ReceiptUploadUsage>();
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,row.Version+1,usage with{Attempts=Enumerable.Repeat(DateTimeOffset.UtcNow,10).ToArray()}),row.Version)]);
        Assert.Equal("receipt_upload_rate_limited",(await Assert.ThrowsAsync<DomainException>(()=>c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),c.GroupId,new(Guid.NewGuid().ToString(),false,[new(Guid.NewGuid().ToString(),"image/jpeg",10,new string('a',64))]),default))).Code);
        await c.PutReceipt((await c.Receipt(id))with{ExpiresAt=DateTimeOffset.UtcNow.AddSeconds(-1)});await c.Worker.ProcessAsync(id);Assert.Equal(0,c.Extractor.Calls);Assert.Equal("cancelled",(await c.Receipt(id)).State);
    }

    [Fact]
    public async Task HourlyAttemptLimitAppliesWhenFailuresDoNotConsumeMonthlyQuota()
    {
        var c=await ReceiptTestContext.Create();await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"USER#{c.Actor.User.Id}","SCAN_ADMISSION",1,new ReceiptAdmission(Enumerable.Repeat(DateTimeOffset.UtcNow,10).ToArray())),null)]);
        var id=await c.CreateReceipt();await c.Worker.ProcessAsync(id);Assert.Equal(0,c.Extractor.Calls);Assert.Equal("scan_rate_limited",(await c.Receipt(id)).ErrorCode);Assert.Equal(0,(await c.Quotas.AllowanceAsync(c.Actor.User.Id,default)).Reserved);
    }

    [Fact]
    public async Task RuntimeEmergencyStopAndBudgetBlockPaidAndFree()
    {
        var c=await ReceiptTestContext.Create();await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create("OPERATIONS","RECEIPTS",1,new ReceiptRuntimeControl(true)),null)]);
        Assert.Equal("scan_paused",(await Assert.ThrowsAsync<DomainException>(()=>c.Budget.AdmitAsync(true,default))).Code);
        await c.Store.TransactAsync([StoreMutation.Delete("OPERATIONS","RECEIPTS",1),StoreMutation.Put(StoreRow.Create("RECEIPT_BUDGET",DateTimeOffset.UtcNow.ToString("yyyyMM"),1,new ReceiptBudget(10_000_000,1000)),null)]);
        await Assert.ThrowsAsync<DomainException>(()=>c.Budget.AdmitAsync(false,default));await Assert.ThrowsAsync<DomainException>(()=>c.Budget.AdmitAsync(true,default));
    }
    [Fact]
    public async Task FiveProviderFailuresOpenCircuit()
    {
        var c=await ReceiptTestContext.Create();await c.Store.TransactAsync(await c.Budget.AdmitAsync(false,default));
        for(var i=0;i<5;i++)await c.Store.TransactAsync(await c.Budget.OutcomeAsync(true,default));
        Assert.Equal("scan_circuit_open",(await Assert.ThrowsAsync<DomainException>(()=>c.Budget.AdmitAsync(true,default))).Code);
    }
    [Fact]
    public async Task UploaderDeletionAnonymizesSharedReceiptButPurgesPrivateDraft()
    {
        var c=await ReceiptTestContext.Create();var shared=await c.CreateReceipt(false);var draft=await c.CreateReceipt(false);await c.PutReceipt((await c.Receipt(shared))with{State="attached",ExpenseId=Guid.NewGuid().ToString()});
        await c.Lifecycle.AnonymizeUserAsync(c.Actor.User.Id);Assert.Null((await c.Receipt(shared)).UploaderId);Assert.False((await c.Receipt(shared)).ImagesRemoved);Assert.True((await c.Receipt(draft)).ImagesRemoved);
        var purge=(await c.Store.GetAsync("WORK#receipt-purge",draft))!;await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(purge.Pk,purge.Sk,purge.Version+1,new ReceiptWork(draft,DateTimeOffset.UtcNow)),purge.Version)]);
        await c.Lifecycle.CleanupAsync();Assert.Contains(draft,c.Blobs.Deleted);Assert.DoesNotContain(shared,c.Blobs.Deleted);
    }
}
