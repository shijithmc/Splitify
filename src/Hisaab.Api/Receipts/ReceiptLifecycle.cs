using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptLifecycle(IAtomicStore store,ReceiptQuotaService quotas,IReceiptBlobStore blobs,IConfiguration config)
{
    public async Task CancelAsync(StoreRow row,CancellationToken ct)
    {
        var receipt=row.Deserialize<ReceiptRecord>();var next=receipt with{State="cancelled",ImagesRemoved=true,ReservationHeld=false,LeaseToken=null,LeaseUntil=null,Generation=receipt.Generation+1,Version=receipt.Version+1,PurgeAt=DateTimeOffset.UtcNow};
        var writes=(await quotas.ReleaseAsync(receipt,false,ct)).ToList();writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,next.Version,next),row.Version));
        var purge=await store.GetAsync("WORK#receipt-purge",receipt.Id,ct);writes.Add(StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",receipt.Id,(purge?.Version??0)+1,new ReceiptWork(receipt.Id,DateTimeOffset.UtcNow.AddMinutes(10))),purge?.Version));
        await store.TransactAsync(writes,ct);
    }
    public async Task EnsureRemovedCleanupAsync(string receiptId,CancellationToken ct)
    {
        var row=await store.GetAsync($"RECEIPT#{receiptId}","META",ct);if(row is null||!row.Deserialize<ReceiptRecord>().ImagesRemoved)return;
        var work=await store.GetAsync("WORK#receipt-purge",receiptId,ct);
        try{await store.TransactAsync([StoreMutation.Condition(row.Pk,row.Sk,row.Version),StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",receiptId,(work?.Version??0)+1,new ReceiptWork(receiptId,DateTimeOffset.UtcNow.AddMinutes(10))),work?.Version)],ct);}catch(StoreConflictException){}
    }
    public async Task AnonymizeUserAsync(string userId,CancellationToken ct=default)
    {
        while(true)
        {
            var page=await store.QueryAsync($"USER#{userId}","RECEIPT#",20,ct:ct);if(page.Items.Count==0)return;
            foreach(var edge in page.Items)
            {
                for(var attempt=0;attempt<6;attempt++)
                {
                    var currentEdge=await store.GetAsync(edge.Pk,edge.Sk,ct);if(currentEdge is null)break;
                    var row=await store.GetAsync(edge.Sk,"META",ct);var writes=new List<StoreMutation>{StoreMutation.Delete(edge.Pk,edge.Sk,currentEdge.Version)};
                    if(row is not null)
                    {
                        var receipt=row.Deserialize<ReceiptRecord>();writes.AddRange(await quotas.ReleaseAsync(receipt,false,ct));writes.AddRange(await new ReceiptUploadAdmission(store,config).ReleaseAsync(receipt,ct));
                        var next=receipt with{UploaderId=null,ReservationHeld=false,LeaseToken=null,LeaseUntil=null,Generation=receipt.Generation+1,Version=receipt.Version+1};
                        if(receipt.ExpenseId is null)
                        {
                            next=next with{State="cancelled",ImagesRemoved=true,PurgeAt=DateTimeOffset.UtcNow};var purge=await store.GetAsync("WORK#receipt-purge",receipt.Id,ct);
                            writes.Add(StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",receipt.Id,(purge?.Version??0)+1,new ReceiptWork(receipt.Id,DateTimeOffset.UtcNow.AddMinutes(10))),purge?.Version));
                        }
                        writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,next.Version,next),row.Version));
                    }
                    try{await store.TransactAsync(writes,ct);break;}catch(StoreConflictException)when(attempt<5){}
                }
            }
        }
    }
    public async Task CleanupAsync(CancellationToken ct=default)
    {
        await CleanupGroupsAsync(ct);
        var checkpoint=await store.GetAsync("JOB#CURSOR","WORK#receipt-purge",ct);var cursor=checkpoint?.Data.GetProperty("cursor").GetString();
        var page=await store.QueryAsync("WORK#receipt-purge","",5,cursor,ct);
        foreach(var work in page.Items)
        {
            if(work.Deserialize<ReceiptWork>().DueAt>DateTimeOffset.UtcNow)continue;
            try{await PurgeAsync(work,ct);}catch(StoreConflictException){}
        }
        try{await store.TransactAsync([StoreMutation.Put(StoreRow.Create("JOB#CURSOR","WORK#receipt-purge",(checkpoint?.Version??0)+1,new{cursor=page.NextCursor}),checkpoint?.Version)],ct);}catch(StoreConflictException){}
    }
    private async Task PurgeAsync(StoreRow work,CancellationToken ct)
    {
        var row=await store.GetAsync($"RECEIPT#{work.Sk}","META",ct);
        if(row is not null)
        {
            var receipt=row.Deserialize<ReceiptRecord>();var due=receipt.ImagesRemoved||receipt.PurgeAt<=DateTimeOffset.UtcNow||receipt.ExpenseId is null&&receipt.ExpiresAt<=DateTimeOffset.UtcNow;
            if(!due)
            {
                if(receipt.ExpenseId is not null&&receipt.PurgeAt is null)await store.TransactAsync([StoreMutation.Delete(work.Pk,work.Sk,work.Version)],ct);
                return;
            }
            if(!receipt.ImagesRemoved)
            {
                var writes=(await quotas.ReleaseAsync(receipt,false,ct)).ToList();var next=receipt with{ImagesRemoved=true,ReservationHeld=false,LeaseToken=null,LeaseUntil=null,Generation=receipt.Generation+1,Version=receipt.Version+1,State=receipt.ExpenseId is null?"expired":receipt.State};
                writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,next.Version,next),row.Version));
                // First tombstone fences validators and renewed upload grants before erasure.
                writes.Add(StoreMutation.Put(StoreRow.Create(work.Pk,work.Sk,work.Version+1,new ReceiptWork(receipt.Id,DateTimeOffset.UtcNow.AddMinutes(10))),work.Version));
                await store.TransactAsync(writes,ct);return;
            }
        }
        // Access is durably revoked before external deletion; replaying deletion is safe.
        await blobs.DeleteAsync(work.Sk,ct);
        var tombstone=await store.GetAsync($"RECEIPT#{work.Sk}","META",ct);
        if(tombstone is not null)
        {
            var record=tombstone.Deserialize<ReceiptRecord>();
            if(record.ExpenseId is null)
            {
                var releases=await new ReceiptUploadAdmission(store,config).ReleaseAsync(record,ct);if(releases.Count>0)await store.TransactAsync(releases,ct);
                // Private discarded drafts contain item/merchant data as well as images.
                // Delete parsed pages after media purge; a resumable tombstone keeps fencing.
                while(true)
                {
                    var page=await store.QueryAsync(tombstone.Pk,"",90,ct:ct);var data=page.Items.Where(x=>x.Sk!="META").ToArray();if(data.Length==0)break;
                    await store.TransactAsync(data.Select(x=>StoreMutation.Delete(x.Pk,x.Sk,x.Version)).ToArray(),ct);
                }
            }
            if(record.Media.Count>0||record.Uploads.Count>0)
                await store.TransactAsync([StoreMutation.Put(StoreRow.Create(tombstone.Pk,tombstone.Sk,tombstone.Version+1,record with{Media=[],Uploads=[],Version=tombstone.Version+1}),tombstone.Version)],ct);
        }
        var latest=await store.GetAsync(work.Pk,work.Sk,ct);if(latest?.Version==work.Version)await store.TransactAsync([StoreMutation.Delete(work.Pk,work.Sk,work.Version)],ct);
    }
    private async Task CleanupGroupsAsync(CancellationToken ct)
    {
        var checkpoint=await store.GetAsync("JOB#CURSOR","WORK#receipt-group-purge",ct);var cursorValue=checkpoint?.Data.GetProperty("cursor").GetString();
        var jobs=await store.QueryAsync("WORK#receipt-group-purge","",5,cursorValue,ct);
        foreach(var job in jobs.Items)
        {
            if(job.Data.GetProperty("dueAt").GetDateTimeOffset()>DateTimeOffset.UtcNow)continue;
            var cursor=job.Data.TryGetProperty("cursor",out var value)?value.GetString():null;
            var page=await store.QueryAsync($"GROUP#{job.Sk}","RECEIPT#",20,cursor,ct);var writes=new List<StoreMutation>();
            foreach(var edge in page.Items)
            {
                var id=edge.Sk[8..];var receiptRow=await store.GetAsync($"RECEIPT#{id}","META",ct);if(receiptRow is null)continue;
                var receipt=receiptRow.Deserialize<ReceiptRecord>();var next=receipt with{ImagesRemoved=true,PurgeAt=DateTimeOffset.UtcNow,Version=receipt.Version+1};writes.Add(StoreMutation.Put(StoreRow.Create(receiptRow.Pk,receiptRow.Sk,next.Version,next),receiptRow.Version));
                var purge=await store.GetAsync("WORK#receipt-purge",id,ct);writes.Add(StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",id,(purge?.Version??0)+1,new ReceiptWork(id,DateTimeOffset.UtcNow)),purge?.Version));
            }
            writes.Add(page.NextCursor is null?StoreMutation.Delete(job.Pk,job.Sk,job.Version):StoreMutation.Put(StoreRow.Create(job.Pk,job.Sk,job.Version+1,new{receiptId=job.Sk,dueAt=DateTimeOffset.UtcNow,cursor=page.NextCursor}),job.Version));
            try{await store.TransactAsync(writes,ct);}catch(StoreConflictException){}
        }
        try{await store.TransactAsync([StoreMutation.Put(StoreRow.Create("JOB#CURSOR","WORK#receipt-group-purge",(checkpoint?.Version??0)+1,new{cursor=jobs.NextCursor}),checkpoint?.Version)],ct);}catch(StoreConflictException){}
    }
}
