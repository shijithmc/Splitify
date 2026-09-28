using System.Text.Json;
using Hisaab.Api.Receipts;
using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;
using Hisaab.Support;
namespace Hisaab.Support.Tests;
public sealed class ReceiptSupportTests
{
    [Fact]
    public async Task HistoricalReceiptLookupReturnsOperationalMetadataWithoutImagesOrIdentitiesAndAuditsAccess()
    {
        var store=new LocalAtomicStore(null);var id=Guid.NewGuid().ToString();var now=DateTimeOffset.UtcNow;
        var record=new ReceiptRecord(id,"sensitive-group","sensitive-uploader","sensitive-participant","failed",true,[new("image","private-object-key","image/jpeg",100,"checksum")],[],now,now.AddDays(1),ErrorCode:"scan_timeout");
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create($"RECEIPT#{id}","META",1,record),null)]);
        var result=await new ReceiptSupportService(store).LookupAsync(id,"INC-123","operator@company");Assert.Equal("scan_timeout",result!.ErrorCode);
        var json=JsonSerializer.Serialize(result);Assert.DoesNotContain("sensitive",json);Assert.DoesNotContain("private-object",json);Assert.DoesNotContain("checksum",json);
        var audit=Assert.Single((await store.QueryAsync("SUPPORT_AUDIT","")).Items);Assert.Equal("lookup-receipt",audit.Data.GetProperty("action").GetString());Assert.Equal("INC-123",audit.Data.GetProperty("ticket").GetString());
    }
    [Fact]
    public async Task MissingReceiptLookupsAreAudited()
    {
        var store=new LocalAtomicStore(null);Assert.Null(await new ReceiptSupportService(store).LookupAsync(Guid.NewGuid().ToString(),"INC-1","operator"));Assert.Single((await store.QueryAsync("SUPPORT_AUDIT","")).Items);
    }
    [Theory]
    [InlineData("","op")]
    [InlineData("INC-1","bad\noperator")]
    public async Task InvalidAuditAnnotationsWriteNothing(string ticket,string op)
    {
        var store=new LocalAtomicStore(null);await Assert.ThrowsAsync<ArgumentException>(()=>new ReceiptSupportService(store).LookupAsync(Guid.NewGuid().ToString(),ticket,op));Assert.Empty((await store.QueryAsync("SUPPORT_AUDIT","")).Items);
    }
}
