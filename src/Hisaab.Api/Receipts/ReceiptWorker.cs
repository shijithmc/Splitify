using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptWorker(IAtomicStore store, IReceiptBlobStore blobs, ReceiptQuotaService quotas,
    ReceiptLifecycle lifecycle, IConfiguration config)
{
    public async Task RunAsync(string? receiptId = null,CancellationToken ct=default)
    {
        if(receiptId is not null){await ProcessAsync(receiptId,ct);return;}
        var checkpoint=await store.GetAsync("JOB#CURSOR","WORK#receipt-scan",ct);var cursor=checkpoint?.Data.GetProperty("cursor").GetString();
        var page=await store.QueryAsync("WORK#receipt-scan","",1,cursor,ct);
        foreach(var row in page.Items) await ProcessAsync(row.Sk,ct);
        try{await store.TransactAsync([StoreMutation.Put(StoreRow.Create("JOB#CURSOR","WORK#receipt-scan",(checkpoint?.Version??0)+1,new{cursor=page.NextCursor}),checkpoint?.Version)],ct);}catch(StoreConflictException){}
        await lifecycle.CleanupAsync(ct);
    }
    public async Task ProcessAsync(string id,CancellationToken ct=default)
    {
        var row=await store.GetAsync($"RECEIPT#{id}","META",ct);var work=await store.GetAsync("WORK#receipt-scan",id,ct);
        if(row is null||work is null)return;var receipt=row.Deserialize<ReceiptRecord>();var now=DateTimeOffset.UtcNow;
        if(work.Deserialize<ReceiptWork>().DueAt>now)return;
        if(receipt.ExpenseId is null&&receipt.ExpiresAt<=now){await lifecycle.CancelAsync(row,ct);return;}
        if(receipt.State is not("validating" or "queued" or "processing")){await DeleteWorkAsync(work,ct);return;}
        if(receipt.State is "queued" or "processing")
        {
            // Fence legacy scans, including active leases: no provider is available in this worker.
            await FinishAsync(row,receipt,work,receipt.Media.Count>0?"manual_ready":"failed",receipt.Media.Count>0?null:"receipt_media_invalid",ct);return;
        }
        if(receipt.LeaseUntil>now)return;
        var profile=receipt.UploaderId is null?null:await store.GetAsync($"USER#{receipt.UploaderId}","PROFILE",ct);
        var groupRow=await store.GetAsync($"GROUP#{receipt.GroupId}","META",ct);var group=groupRow?.Deserialize<Group>();
        if(profile?.Deserialize<UserAccount>().Status!="active"||group is null||group.Deleted||!group.Members.Any(m=>m.UserId==receipt.UploaderId&&!m.HasLeft&&!m.IsDeleted))
        {await lifecycle.CancelAsync(row,ct);return;}
        var token=Ids.Token();var claimed=receipt with{LeaseToken=token,LeaseUntil=now.AddSeconds(45),Version=receipt.Version+1};var writes=new List<StoreMutation>{StoreMutation.Condition(profile!.Pk,profile.Sk,profile.Version),StoreMutation.Condition(groupRow!.Pk,groupRow.Sk,groupRow.Version)};
        var claimedRow=StoreRow.Create(row.Pk,row.Sk,claimed.Version,claimed);writes.Add(StoreMutation.Put(claimedRow,row.Version));
        try{await store.TransactAsync(writes,ct);}catch(StoreConflictException){return;}
        if(receipt.State=="validating")
        {
            try
            {
                var media=await blobs.ValidateAsync(id,claimed.Uploads,ct);
                if(media.Count!=claimed.Uploads.Count||media.Any(m=>m.SizeBytes>10*1024*1024||m.Width>2048||m.Height>2048||m.Width<1||m.Height<1))throw new DomainException(422,"receipt_media_invalid","Invalid receipt image.");
                var latest=await store.GetAsync(row.Pk,row.Sk,ct);if(latest?.Version!=claimedRow.Version){await lifecycle.EnsureRemovedCleanupAsync(id,ct);return;}
                var currentProfile=await store.GetAsync(profile!.Pk,profile.Sk,ct);var currentGroupRow=await store.GetAsync(groupRow!.Pk,groupRow.Sk,ct);var currentGroup=currentGroupRow?.Deserialize<Group>();
                if(claimed.ExpiresAt<=DateTimeOffset.UtcNow||currentProfile?.Deserialize<UserAccount>().Status!="active"||currentGroup is null||currentGroup.Deleted||!currentGroup.Members.Any(m=>m.UserId==claimed.UploaderId&&!m.HasLeft&&!m.IsDeleted)){await lifecycle.CancelAsync(latest,ct);return;}
                var next=claimed with{ExpiresAt=DateTimeOffset.UtcNow.AddDays(7),Media=media,State="manual_ready",ScanRequested=false,ReservationHeld=false,LeaseToken=null,LeaseUntil=null,ErrorCode=null,Version=claimed.Version+1};
                var final=new List<StoreMutation>{StoreMutation.Condition(currentProfile!.Pk,currentProfile.Sk,currentProfile.Version),StoreMutation.Condition(currentGroupRow!.Pk,currentGroupRow.Sk,currentGroupRow.Version),StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,next.Version,next),claimedRow.Version)};
                final.AddRange(await quotas.ReleaseAsync(claimed,false,ct));
                final.AddRange(await new ReceiptUploadAdmission(store,config).ExtendAsync(claimed,next.ExpiresAt,ct));
                var expiry=await store.GetAsync("WORK#receipt-purge",id,ct);final.Add(StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",id,(expiry?.Version??0)+1,new ReceiptWork(id,next.ExpiresAt)),expiry?.Version));
                final.Add(StoreMutation.Delete(work.Pk,work.Sk,work.Version));
                await store.TransactAsync(final,ct);
            }
            catch(DomainException ex){await FinishAsync(claimedRow,claimed,work,"failed",ex.Code,ct);}
            catch(StoreConflictException){}
            return;
        }
    }
    private async Task FinishAsync(StoreRow claimedRow,ReceiptRecord claimed,StoreRow work,string state,string? error,CancellationToken ct)
    {
        for(var attempt=0;attempt<5;attempt++)
        {
            var row=await store.GetAsync(claimedRow.Pk,claimedRow.Sk,ct);if(row?.Version!=claimedRow.Version)return;
            var receipt=row.Deserialize<ReceiptRecord>();if(receipt.LeaseToken!=claimed.LeaseToken||receipt.Generation!=claimed.Generation||receipt.ExpenseId is not null||receipt.ImagesRemoved)return;
            var active=receipt.UploaderId is null?null:await store.GetAsync($"USER#{receipt.UploaderId}","PROFILE",ct);var groupRow=await store.GetAsync($"GROUP#{receipt.GroupId}","META",ct);var group=groupRow?.Deserialize<Group>();
            if(receipt.ExpiresAt<=DateTimeOffset.UtcNow||active?.Deserialize<UserAccount>().Status!="active"||group is null||group.Deleted||!group.Members.Any(m=>m.UserId==receipt.UploaderId&&!m.HasLeft&&!m.IsDeleted)){await lifecycle.CancelAsync(row,ct);return;}
            var next=receipt with{State=state,ScanRequested=false,Version=receipt.Version+1,Generation=receipt.Generation+1,LeaseToken=null,LeaseUntil=null,ErrorCode=error,ReservationHeld=false};
            var writes=new List<StoreMutation>{StoreMutation.Condition(active!.Pk,active.Sk,active.Version),StoreMutation.Condition(groupRow!.Pk,groupRow.Sk,groupRow.Version)};
            writes.AddRange(await quotas.ReleaseAsync(receipt,false,ct));
            writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,next.Version,next),row.Version));
            var currentWork=await store.GetAsync(work.Pk,work.Sk,ct);if(currentWork is not null)
                writes.Add(StoreMutation.Delete(work.Pk,work.Sk,currentWork.Version));
            try{await store.TransactAsync(writes,ct);return;}catch(StoreConflictException)when(attempt<4){}
        }
    }
    private async Task DeleteWorkAsync(StoreRow work,CancellationToken ct)
    {try{await store.TransactAsync([StoreMutation.Delete(work.Pk,work.Sk,work.Version)],ct);}catch(StoreConflictException){}}
}
