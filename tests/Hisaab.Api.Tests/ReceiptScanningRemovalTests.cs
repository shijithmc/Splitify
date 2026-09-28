using System.Net;
using System.Text.Json;
using Hisaab.Api.Receipts;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;

namespace Hisaab.Api.Tests;

public sealed class ReceiptScanningRemovalTests
{
    [Fact]
    public async Task ScanCreateIsGoneBeforeValidationOrLegacyIdempotencyReplay()
    {
        var c=await ReceiptTestContext.Create();var id=Guid.NewGuid().ToString();var key=Guid.NewGuid().ToString();
        var request=new ReceiptCreateRequest(id,true,[new(Guid.NewGuid().ToString(),"image/jpeg",10,new string('a',64))]);
        await new CommandExecutor(c.Store).ExecuteAsync(c.Actor,key,$"receipts:create:{c.GroupId}",request,()=>Task.FromResult(new MutationResult(new{id},[])));
        var replay=await Assert.ThrowsAsync<DomainException>(()=>c.Service.CreateAsync(c.Actor,key,c.GroupId,request,default));
        Assert.Equal(410,replay.Status);Assert.Equal("ai_scanning_removed",replay.Code);
        var malformed=await Assert.ThrowsAsync<DomainException>(()=>c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),"missing",new("invalid",true,[]),default));
        Assert.Equal("ai_scanning_removed",malformed.Code);
        Assert.Null(await c.Store.GetAsync($"RECEIPT#{id}","META"));
        Assert.Null(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_UPLOAD_ADMISSION"));
        Assert.Empty((await c.Store.QueryAsync("WORK#receipt-scan","")).Items);
    }

    [Fact]
    public async Task ScanCreateHttpReturnsGoneWithoutIssuingUploadGrants()
    {
        await using var factory=new ApiFactory();var j=await GroupJourney.Create(factory);var request=Request()with{ScanRequested=true};
        var error=await ApiSession.Error(j.Alice.Client,HttpMethod.Post,$"{j.GroupPath}/receipts",HttpStatusCode.Gone,request);
        Assert.Equal("ai_scanning_removed",error.GetProperty("code").GetString());
        Assert.Null(await factory.Store.GetAsync($"RECEIPT#{request.Id}","META"));
        Assert.Null(await factory.Store.GetAsync($"USER#{j.Alice.UserId}","RECEIPT_UPLOAD_ADMISSION"));
    }

    [Theory]
    [InlineData("GET","/v1/receipts/allowance")]
    [InlineData("PUT","/v1/receipts/consent")]
    [InlineData("POST","/v1/receipts/unused/retry")]
    public async Task RemovedRoutesReturnGoneToAuthenticatedLegacyClients(string method,string route)
    {
        await using var factory=new ApiFactory();var user=await ApiSession.Login(factory,"Alice");
        object? body=method=="PUT"?new{version="2026-09-26-v1",accepted=true}:method=="POST"?new{version=1}:null;
        var error=await ApiSession.Error(user.Client,new HttpMethod(method),route,HttpStatusCode.Gone,body);
        Assert.Equal("ai_scanning_removed",error.GetProperty("code").GetString());
        Assert.Null(await factory.Store.GetAsync($"USER#{user.UserId}","RECEIPT_CONSENT"));
    }

    [Theory]
    [InlineData("queued",false)]
    [InlineData("processing",false)]
    [InlineData("processing",true)]
    public async Task LegacyPendingScansBecomeManualAndReleaseQuotaExactlyOnce(string state,bool activeLease)
    {
        var c=await ReceiptTestContext.Create();var id=await c.CreateReceipt();var receipt=await c.Receipt(id);var month=ReceiptQuotaService.Month(DateTimeOffset.UtcNow);
        await c.PutReceipt(receipt with{State=state,ScanRequested=true,ReservationHeld=true,QuotaMonth=month,Attempts=2,Generation=3,LeaseToken="old-provider",LeaseUntil=DateTimeOffset.UtcNow.AddMinutes(activeLease?1:-1)});
        await c.Store.TransactAsync([
            StoreMutation.Put(StoreRow.Create($"USER#{c.Actor.User.Id}",$"SCAN_QUOTA#{month}",1,new ReceiptQuota(2,1)),null),
            StoreMutation.Put(StoreRow.Create("WORK#receipt-scan",id,1,new ReceiptWork(id,DateTimeOffset.UtcNow)),null)]);
        await Task.WhenAll(c.Worker.ProcessAsync(id),c.Worker.ProcessAsync(id));await c.Worker.ProcessAsync(id);
        var updated=await c.Receipt(id);Assert.Equal("manual_ready",updated.State);Assert.False(updated.ScanRequested);Assert.False(updated.ReservationHeld);
        Assert.Null(updated.LeaseToken);Assert.Null(updated.LeaseUntil);Assert.Equal(4,updated.Generation);Assert.Equal(2,updated.Attempts);Assert.Equal(receipt.Media.ToArray(),updated.Media.ToArray());Assert.False(updated.ImagesRemoved);
        var quota=(await c.Store.GetAsync($"USER#{c.Actor.User.Id}",$"SCAN_QUOTA#{month}"))!.Deserialize<ReceiptQuota>();Assert.Equal(0,quota.Reserved);Assert.Equal(2,quota.Used);
        Assert.Null(await c.Store.GetAsync("WORK#receipt-scan",id));Assert.Empty((await c.Store.QueryAsync($"GROUP#{c.GroupId}","EXPENSE#")).Items);
        Assert.Empty((await c.Store.QueryAsync("RECEIPT_BUDGET","")).Items);
    }

    [Fact]
    public async Task LegacyValidatingUploadNormalizesToManualWithoutScanWork()
    {
        var c=await ReceiptTestContext.Create();var request=Request();
        await c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),c.GroupId,request,default);
        await c.Service.CompleteAsync(c.Actor,Guid.NewGuid().ToString(),request.Id,new(1),default);
        await c.PutReceipt((await c.Receipt(request.Id))with{ScanRequested=true});
        await c.Worker.ProcessAsync(request.Id);
        var receipt=await c.Receipt(request.Id);Assert.Equal("manual_ready",receipt.State);Assert.False(receipt.ScanRequested);Assert.Single(receipt.Media);Assert.False(receipt.Counted);Assert.Equal(0,receipt.Attempts);
        Assert.Null(await c.Store.GetAsync("WORK#receipt-scan",request.Id));
    }

    [Fact]
    public async Task LegacyUnfinishedUploadCanBeResumedManuallyAndReplayDoesNotDuplicateAdmission()
    {
        var c=await ReceiptTestContext.Create();var request=Request();
        await c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),c.GroupId,request,default);
        await c.PutReceipt((await c.Receipt(request.Id))with{ScanRequested=true});var key=Guid.NewGuid().ToString();
        var attempts=await Task.WhenAll(c.Service.CreateAsync(c.Actor,key,c.GroupId,request,default),c.Service.CreateAsync(c.Actor,key,c.GroupId,request,default));
        Assert.All(attempts,value=>Assert.Single(JsonSerializer.SerializeToElement(value,JsonDefaults.Options).GetProperty("uploads").EnumerateArray()));
        var receipt=await c.Receipt(request.Id);Assert.False(receipt.ScanRequested);Assert.Equal(3,receipt.Version);Assert.Single(receipt.Uploads);
        var admission=(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_UPLOAD_ADMISSION"))!.Deserialize<ReceiptUploadUsage>();Assert.Single(admission.Attempts);Assert.Single(admission.Reservations);
        await c.Service.CompleteAsync(c.Actor,Guid.NewGuid().ToString(),receipt.Id,new(receipt.Version),default);await c.Worker.ProcessAsync(receipt.Id);Assert.Equal("manual_ready",(await c.Receipt(receipt.Id)).State);
    }

    [Theory]
    [InlineData("different_uploader")]
    [InlineData("different_image")]
    [InlineData("expired")]
    [InlineData("removed")]
    [InlineData("failed")]
    [InlineData("ordinary_duplicate")]
    public async Task DraftMigrationCannotClaimOtherReceiptsOrReviveInvalidDrafts(string change)
    {
        var c=await ReceiptTestContext.Create();var request=Request();await c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),c.GroupId,request,default);
        var receipt=await c.Receipt(request.Id);await c.PutReceipt(receipt with{ScanRequested=change!="ordinary_duplicate",UploaderId=change=="different_uploader"?c.Other.User.Id:receipt.UploaderId,ExpiresAt=change=="expired"?DateTimeOffset.UtcNow.AddSeconds(-1):receipt.ExpiresAt,ImagesRemoved=change=="removed",State=change=="failed"?"failed":receipt.State});
        if(change=="different_image")request=request with{Images=[request.Images[0]with{Sha256=new string('b',64)}]};
        var before=await c.Receipt(receipt.Id);
        Assert.Equal("receipt_exists",(await Assert.ThrowsAsync<DomainException>(()=>c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),c.GroupId,request,default))).Code);
        Assert.Equal(JsonSerializer.Serialize(before),JsonSerializer.Serialize(await c.Receipt(receipt.Id)));
    }

    [Fact]
    public async Task HistoricalReadingAndMediaRemainAvailable()
    {
        var c=await ReceiptTestContext.Create();var id=await c.CreateReceipt();await c.PutReceipt((await c.Receipt(id))with{State="ready",Counted=true,ScanRequested=true,Generation=7});
        await c.Store.TransactAsync(ReceiptDocuments.Create(id,"SCAN#0007",new ReceiptExtraction("bill",JsonSerializer.SerializeToElement(new{merchant="Existing cafe"}),"old-model","1","1",[])));
        var result=JsonSerializer.SerializeToElement(await c.Service.GetAsync(c.Actor,id,default),JsonDefaults.Options);
        Assert.Equal("Existing cafe",result.GetProperty("extraction").GetProperty("document").GetProperty("merchant").GetString());Assert.Single(result.GetProperty("media").EnumerateArray());Assert.True(result.GetProperty("manualAvailable").GetBoolean());
    }

    [Fact]
    public async Task CancelledUploadCannotBeResurrectedByLateImageNormalization()
    {
        var c=await ReceiptTestContext.Create();var request=Request();await c.Service.CreateAsync(c.Actor,Guid.NewGuid().ToString(),c.GroupId,request,default);
        await c.Service.CompleteAsync(c.Actor,Guid.NewGuid().ToString(),request.Id,new(1),default);
        var started=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);var release=new TaskCompletionSource<IReadOnlyList<ReceiptMedia>>(TaskCreationOptions.RunContinuationsAsynchronously);
        c.Blobs.Validation=(_,_)=>{started.SetResult();return release.Task;};var running=c.Worker.ProcessAsync(request.Id);await started.Task;
        await c.Lifecycle.CancelAsync((await c.Store.GetAsync($"RECEIPT#{request.Id}","META"))!,default);
        release.SetResult([new(request.Images[0].Id,"image","thumb","image/jpeg",10,new string('a',64),100,100,3)]);await running;
        var receipt=await c.Receipt(request.Id);Assert.Equal("cancelled",receipt.State);Assert.True(receipt.ImagesRemoved);Assert.Empty(receipt.Media);
    }

    private static ReceiptCreateRequest Request()=>new(Guid.NewGuid().ToString(),false,[new(Guid.NewGuid().ToString(),"image/jpeg",10,new string('a',64))]);
}
