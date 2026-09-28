using System.Text.Json;
using Hisaab.Api.Receipts;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Tests;
public sealed class ReceiptOrchestrationTests
{
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
    public async Task UploaderDeletionAnonymizesSharedReceiptButPurgesPrivateDraft()
    {
        var c=await ReceiptTestContext.Create();var shared=await c.CreateReceipt(false);var draft=await c.CreateReceipt(false);await c.PutReceipt((await c.Receipt(shared))with{State="attached",ExpenseId=Guid.NewGuid().ToString()});
        await c.Lifecycle.AnonymizeUserAsync(c.Actor.User.Id);Assert.Null((await c.Receipt(shared)).UploaderId);Assert.False((await c.Receipt(shared)).ImagesRemoved);Assert.True((await c.Receipt(draft)).ImagesRemoved);
        var purge=(await c.Store.GetAsync("WORK#receipt-purge",draft))!;await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(purge.Pk,purge.Sk,purge.Version+1,new ReceiptWork(draft,DateTimeOffset.UtcNow)),purge.Version)]);
        await c.Lifecycle.CleanupAsync();Assert.Contains(draft,c.Blobs.Deleted);Assert.DoesNotContain(shared,c.Blobs.Deleted);
    }
    [Fact]
    public async Task ManualUploadSessionsRetainIndependentHourlyRateLimit()
    {
        var c=await ReceiptTestContext.Create();await c.CreateReceipt(false);
        var row=(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_UPLOAD_ADMISSION"))!;var usage=row.Deserialize<ReceiptUploadUsage>();
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,row.Version+1,usage with{Attempts=Enumerable.Repeat(DateTimeOffset.UtcNow,10).ToArray()}),row.Version)]);
        var id=Guid.NewGuid().ToString();
        var error=await Assert.ThrowsAsync<DomainException>(()=>c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),c.GroupId,new(id,false,[new(Guid.NewGuid().ToString(),"image/jpeg",10,new string('a',64))]),default));
        Assert.Equal(429,error.Status);Assert.Equal("receipt_upload_rate_limited",error.Code);
        Assert.Null(await c.Store.GetAsync($"RECEIPT#{id}","META"));
        Assert.Null(await c.Store.GetAsync("WORK#receipt-purge",id));
        var after=(await c.Store.GetAsync(row.Pk,row.Sk))!.Deserialize<ReceiptUploadUsage>();Assert.Equal(10,after.Attempts.Count);Assert.Single(after.Reservations);
    }
}
