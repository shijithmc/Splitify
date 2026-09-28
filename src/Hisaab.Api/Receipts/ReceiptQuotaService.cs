using Hisaab.Application.Storage;
namespace Hisaab.Api.Receipts;

// Retained only to release reservations held by receipts created before AI scanning was removed.
public sealed class ReceiptQuotaService
{
    private readonly IAtomicStore store;
    public ReceiptQuotaService(IAtomicStore store,IConfiguration config){this.store=store;}
    public static string Month(DateTimeOffset now)=>now.ToOffset(TimeSpan.FromMinutes(330)).ToString("yyyyMM",System.Globalization.CultureInfo.InvariantCulture);
    public async Task<IReadOnlyList<StoreMutation>> ReleaseAsync(ReceiptRecord receipt,bool success,CancellationToken ct)
    {
        if(!receipt.ReservationHeld||receipt.UploaderId is null||receipt.QuotaMonth is null) return [];
        var row=await store.GetAsync($"USER#{receipt.UploaderId}",$"SCAN_QUOTA#{receipt.QuotaMonth}",ct)??throw new InvalidOperationException("Missing scan reservation.");
        var quota=row.Deserialize<ReceiptQuota>(); if(quota.Reserved<=0)throw new InvalidOperationException("Invalid scan reservation.");
        return [StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,row.Version+1,quota with{Reserved=quota.Reserved-1,Used=quota.Used+(success&&!receipt.Counted?1:0)}),row.Version)];
    }
}
