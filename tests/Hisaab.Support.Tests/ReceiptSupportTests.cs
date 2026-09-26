using System.Text.Json;
using Hisaab.Api.Receipts;
using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;
using Hisaab.Support;
namespace Hisaab.Support.Tests;
public sealed class ReceiptSupportTests
{
    [Fact]
    public async Task ScanLookupReturnsOperationalMetadataWithoutImagesOrIdentitiesAndAuditsAccess()
    {
        var store=new LocalAtomicStore(null);var id=Guid.NewGuid().ToString();var now=DateTimeOffset.UtcNow;
        var record=new ReceiptRecord(id,"sensitive-group","sensitive-uploader","sensitive-participant","failed",true,[new("image","private-object-key","image/jpeg",100,"checksum")],[],now,now.AddDays(1),ErrorCode:"scan_timeout");
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create($"RECEIPT#{id}","META",1,record),null)]);
        var result=await new ReceiptSupportService(store).LookupAsync(id,"INC-123","operator@company");Assert.Equal("scan_timeout",result!.ErrorCode);
        var json=JsonSerializer.Serialize(result);Assert.DoesNotContain("sensitive",json);Assert.DoesNotContain("private-object",json);Assert.DoesNotContain("checksum",json);
        var audit=Assert.Single((await store.QueryAsync("SUPPORT_AUDIT","")).Items);Assert.Equal("lookup-scan",audit.Data.GetProperty("action").GetString());Assert.Equal("INC-123",audit.Data.GetProperty("ticket").GetString());
    }
    [Fact]
    public async Task MissingReceiptLookupsAreAudited()
    {
        var store=new LocalAtomicStore(null);Assert.Null(await new ReceiptSupportService(store).LookupAsync(Guid.NewGuid().ToString(),"INC-1","operator"));Assert.Single((await store.QueryAsync("SUPPORT_AUDIT","")).Items);
    }
    [Fact]
    public async Task PauseFreePreservesEmergencyStopAndOnlyResumeClearsBoth()
    {
        var store=new LocalAtomicStore(null);var service=new ReceiptSupportService(store);Assert.True((await service.ControlAsync("stop","INC-1","op",true)).EmergencyStop);
        var paused=await service.ControlAsync("pause-free","INC-1","op",true);Assert.True(paused.EmergencyStop);Assert.True(paused.PauseFree);
        var resumed=await service.ControlAsync("resume","INC-1","op",true);Assert.False(resumed.EmergencyStop);Assert.False(resumed.PauseFree);Assert.Equal(3,(await store.QueryAsync("SUPPORT_AUDIT","")).Items.Count);
    }
    [Theory]
    [InlineData("stop","INC-1","op",false)]
    [InlineData("bad","INC-1","op",true)]
    [InlineData("stop","","op",true)]
    [InlineData("stop","INC-1","bad\noperator",true)]
    public async Task InvalidOrUnconfirmedControlsWriteNothing(string mode,string ticket,string op,bool confirmed)
    {
        var store=new LocalAtomicStore(null);await Assert.ThrowsAsync<ArgumentException>(()=>new ReceiptSupportService(store).ControlAsync(mode,ticket,op,confirmed));Assert.Null(await store.GetAsync("OPERATIONS","RECEIPTS"));Assert.Empty((await store.QueryAsync("SUPPORT_AUDIT","")).Items);
    }
}
