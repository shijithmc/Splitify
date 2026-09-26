using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptUploadAdmission(IAtomicStore store,IConfiguration config)
{
    public async Task<StoreMutation> ReserveAsync(ReceiptRecord receipt,CancellationToken ct)
    {
        var pk=$"USER#{receipt.UploaderId}";var row=await store.GetAsync(pk,"RECEIPT_UPLOAD_ADMISSION",ct);var now=DateTimeOffset.UtcNow;
        var usage=row?.Deserialize<ReceiptUploadUsage>()??new([],[]);var attempts=usage.Attempts.Where(t=>t>now.AddHours(-1)).ToList();
        if(attempts.Count>=10)throw new DomainException(429,"receipt_upload_rate_limited","Ten bill upload sessions per hour. Enter manually without a photo or try later.");
        var reservations=usage.Reservations.Where(r=>r.ExpiresAt>now).ToList();var bytes=receipt.Uploads.Sum(x=>x.SizeBytes);var maximum=config.GetValue<long?>("Hisaab:Receipts:MaxPendingUploadBytes")??300L*1024*1024;
        if(maximum<=0||reservations.Count>=100||bytes>maximum-reservations.Sum(x=>x.Bytes))throw new DomainException(429,"receipt_upload_storage_limit","Finish or remove a pending bill before uploading another. Manual entry remains available.");
        attempts.Add(now);reservations.Add(new(receipt.Id,bytes,receipt.ExpiresAt));
        return StoreMutation.Put(StoreRow.Create(pk,"RECEIPT_UPLOAD_ADMISSION",(row?.Version??0)+1,new ReceiptUploadUsage(attempts,reservations)),row?.Version);
    }
    public async Task<IReadOnlyList<StoreMutation>> ExtendAsync(ReceiptRecord receipt,DateTimeOffset expiresAt,CancellationToken ct)
    {
        if(receipt.UploaderId is null)return [];
        var row=await store.GetAsync($"USER#{receipt.UploaderId}","RECEIPT_UPLOAD_ADMISSION",ct);if(row is null)throw new InvalidOperationException("Upload reservation is missing.");
        var usage=row.Deserialize<ReceiptUploadUsage>();if(!usage.Reservations.Any(r=>r.ReceiptId==receipt.Id))throw new DomainException(409,"receipt_upload_expired","This upload expired. Create a new receipt.");
        return [StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,row.Version+1,usage with{Reservations=usage.Reservations.Select(r=>r.ReceiptId==receipt.Id?r with{ExpiresAt=expiresAt}:r).ToArray()}),row.Version)];
    }
    public async Task<IReadOnlyList<StoreMutation>> ReleaseAsync(ReceiptRecord receipt,CancellationToken ct)
    {
        if(receipt.UploaderId is null)return [];
        var row=await store.GetAsync($"USER#{receipt.UploaderId}","RECEIPT_UPLOAD_ADMISSION",ct);if(row is null)return [];
        var usage=row.Deserialize<ReceiptUploadUsage>();if(!usage.Reservations.Any(r=>r.ReceiptId==receipt.Id))return [];
        return [StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,row.Version+1,usage with{Reservations=usage.Reservations.Where(r=>r.ReceiptId!=receipt.Id).ToArray()}),row.Version)];
    }
}
