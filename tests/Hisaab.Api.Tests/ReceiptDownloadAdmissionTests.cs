using Hisaab.Api.Receipts;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Tests;

public sealed class ReceiptDownloadAdmissionTests
{
    [Fact]
    public async Task ConcurrentDownloadsReserveExactBytesAndCannotOvershootHourlyBudget()
    {
        var c=await ReceiptTestContext.Create();c.Config["Hisaab:Receipts:MaxDownloadBytesPerHour"]="100";
        var admission=new ReceiptDownloadAdmission(c.Store,c.Config);
        var outcomes=await Task.WhenAll(Enumerable.Range(0,10).Select(async _=>
        {try{await admission.AdmitAsync(c.Actor,20);return "ok";}catch(DomainException ex){return ex.Code;}}));
        Assert.Equal(5,outcomes.Count(x=>x=="ok"));Assert.Equal(5,outcomes.Count(x=>x=="receipt_download_rate_limited"));
        var usage=(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_DOWNLOAD_ADMISSION"))!.Deserialize<ReceiptDownloadUsage>();Assert.Equal(100,usage.Buckets.Sum(x=>x.Bytes));
    }
    [Fact]
    public async Task SixtyChunksPerMinuteCannotBeBypassedUsingTinyRanges()
    {
        var c=await ReceiptTestContext.Create();var minute=DateTimeOffset.UtcNow.ToUnixTimeSeconds()/60;
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"USER#{c.Actor.User.Id}","RECEIPT_DOWNLOAD_ADMISSION",1,new ReceiptDownloadUsage([new(minute,60,60)])),null)]);
        var error=await Assert.ThrowsAsync<DomainException>(()=>new ReceiptDownloadAdmission(c.Store,c.Config).AdmitAsync(c.Actor,1));Assert.Equal("receipt_download_rate_limited",error.Code);
        Assert.Equal(1,(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_DOWNLOAD_ADMISSION"))!.Version);
    }
    [Fact]
    public async Task OldBucketsExpireWhilePartialHourRemainsConservativelyCharged()
    {
        var c=await ReceiptTestContext.Create();c.Config["Hisaab:Receipts:MaxDownloadBytesPerHour"]="20";var minute=DateTimeOffset.UtcNow.ToUnixTimeSeconds()/60;
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"USER#{c.Actor.User.Id}","RECEIPT_DOWNLOAD_ADMISSION",1,new ReceiptDownloadUsage([new(minute-61,1000,60),new(minute-60,10,1)])),null)]);
        var admission=new ReceiptDownloadAdmission(c.Store,c.Config);await admission.AdmitAsync(c.Actor,10);
        await Assert.ThrowsAsync<DomainException>(()=>admission.AdmitAsync(c.Actor,1));
        var usage=(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_DOWNLOAD_ADMISSION"))!.Deserialize<ReceiptDownloadUsage>();Assert.Equal(20,usage.Buckets.Sum(x=>x.Bytes));Assert.Equal(2,usage.Buckets.Count);
    }
    [Fact]
    public async Task RevokedSessionCannotReserveDownloadBytes()
    {
        var c=await ReceiptTestContext.Create();await c.Store.TransactAsync([StoreMutation.Delete($"SESSION#{c.Actor.SessionHash}","META",1)]);
        var error=await Assert.ThrowsAsync<DomainException>(()=>new ReceiptDownloadAdmission(c.Store,c.Config).AdmitAsync(c.Actor,10));Assert.Equal(401,error.Status);
        Assert.Null(await c.Store.GetAsync($"USER#{c.Actor.User.Id}","RECEIPT_DOWNLOAD_ADMISSION"));
    }
}
