using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptWorker(IAtomicStore store, IReceiptBlobStore blobs, IReceiptExtractor extractor,
    ReceiptQuotaService quotas, ReceiptLifecycle lifecycle, ReceiptBudgetService budget, IConfiguration config)
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
        if(receipt.LeaseUntil>now)return;
        if(receipt.State=="processing")
        {
            // An expired lease may have incurred a provider charge. Fence it and count that
            // attempt rather than issuing an unbounded automatic replacement.
            await FinishAsync(row,receipt,work,null,"scan_interrupted",receipt.Attempts<2,ct);return;
        }
        var profile=receipt.UploaderId is null?null:await store.GetAsync($"USER#{receipt.UploaderId}","PROFILE",ct);
        var groupRow=await store.GetAsync($"GROUP#{receipt.GroupId}","META",ct);var group=groupRow?.Deserialize<Group>();
        if(profile?.Deserialize<UserAccount>().Status!="active"||group is null||group.Deleted||!group.Members.Any(m=>m.UserId==receipt.UploaderId&&!m.HasLeft&&!m.IsDeleted))
        {await lifecycle.CancelAsync(row,ct);return;}
        var token=Ids.Token();var claimed=receipt with{LeaseToken=token,LeaseUntil=now.AddSeconds(45),Version=receipt.Version+1};var writes=new List<StoreMutation>{StoreMutation.Condition(profile!.Pk,profile.Sk,profile.Version),StoreMutation.Condition(groupRow!.Pk,groupRow.Sk,groupRow.Version)};
        if(receipt.State=="queued")
        {
            if(receipt.Attempts>=3){await FinishAsync(row,receipt,work,null,"scan_attempt_limit",false,ct);return;}
            try{var reservation=await quotas.ReserveAsync(receipt,ct);claimed=reservation.Receipt with{State="processing",LeaseToken=token,LeaseUntil=now.AddSeconds(45),Attempts=receipt.Attempts+1,Version=receipt.Version+1};writes.AddRange(reservation.Writes);var plan=await quotas.PlanAsync(receipt.UploaderId!,ct);writes.AddRange(await budget.AdmitAsync(plan.Cap==100,ct));}
            catch(DomainException ex){await FinishAsync(row,receipt,work,null,ex.Code,false,ct);return;}
        }
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
                var next=claimed with{ExpiresAt=DateTimeOffset.UtcNow.AddDays(7),Media=media,State=claimed.ScanRequested?"queued":"manual_ready",LeaseToken=null,LeaseUntil=null,Version=claimed.Version+1};
                var final=new List<StoreMutation>{StoreMutation.Condition(currentProfile!.Pk,currentProfile.Sk,currentProfile.Version),StoreMutation.Condition(currentGroupRow!.Pk,currentGroupRow.Sk,currentGroupRow.Version),StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,next.Version,next),claimedRow.Version)};
                final.AddRange(await new ReceiptUploadAdmission(store,config).ExtendAsync(claimed,next.ExpiresAt,ct));
                var expiry=await store.GetAsync("WORK#receipt-purge",id,ct);final.Add(StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",id,(expiry?.Version??0)+1,new ReceiptWork(id,next.ExpiresAt)),expiry?.Version));
                if(!claimed.ScanRequested)final.Add(StoreMutation.Delete(work.Pk,work.Sk,work.Version));
                else final.Add(StoreMutation.Put(StoreRow.Create(work.Pk,work.Sk,work.Version+1,new ReceiptWork(id,DateTimeOffset.UtcNow)),work.Version));
                await store.TransactAsync(final,ct);
            }
            catch(DomainException ex){await FinishAsync(claimedRow,claimed,work,null,ex.Code,false,ct);}
            catch(StoreConflictException){}
            return;
        }
        ReceiptExtraction? extraction=null;string? error=null;var transient=false;
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(ct);timeout.CancelAfter(TimeSpan.FromSeconds(20));
        try
        {
            extraction=await extractor.ExtractAsync(claimed.Media,timeout.Token);
            if(extraction.Classification is not("bill" or "not_bill" or "unreadable")||extraction.Classification=="bill"&&extraction.Document is null)
            {extraction=null;error="scan_output_invalid";}
        }
        catch(ReceiptProviderException ex){error=ex.Code;transient=ex.Transient;}
        catch(OperationCanceledException)when(!ct.IsCancellationRequested){error="scan_timeout";transient=true;}
        catch(HttpRequestException){error="scan_provider_unavailable";transient=true;}
        catch(System.Text.Json.JsonException){error="scan_output_invalid";}
        catch(Exception ex)when(ex is not OperationCanceledException){error="scan_provider_unavailable";transient=false;}
        if(ct.IsCancellationRequested)return; // Expired-lease repair fences this generation later.
        await FinishAsync(claimedRow,claimed,work,extraction,error,transient&&claimed.Attempts<2,ct);
    }
    private async Task FinishAsync(StoreRow claimedRow,ReceiptRecord claimed,StoreRow work,ReceiptExtraction? extraction,string? error,bool retry,CancellationToken ct)
    {
        for(var attempt=0;attempt<5;attempt++)
        {
            var row=await store.GetAsync(claimedRow.Pk,claimedRow.Sk,ct);if(row?.Version!=claimedRow.Version)return;
            var receipt=row.Deserialize<ReceiptRecord>();if(receipt.LeaseToken!=claimed.LeaseToken||receipt.Generation!=claimed.Generation||receipt.ExpenseId is not null||receipt.ImagesRemoved)return;
            var active=receipt.UploaderId is null?null:await store.GetAsync($"USER#{receipt.UploaderId}","PROFILE",ct);var groupRow=await store.GetAsync($"GROUP#{receipt.GroupId}","META",ct);var group=groupRow?.Deserialize<Group>();
            if(receipt.ExpiresAt<=DateTimeOffset.UtcNow||active?.Deserialize<UserAccount>().Status!="active"||group is null||group.Deleted||!group.Members.Any(m=>m.UserId==receipt.UploaderId&&!m.HasLeft&&!m.IsDeleted)){await lifecycle.CancelAsync(row,ct);return;}
            var success=extraction?.Classification=="bill";var state=success?"ready":extraction?.Classification??(retry?"queued":"failed");var next=receipt with{State=state,Version=receipt.Version+1,LeaseToken=null,LeaseUntil=null,ErrorCode=error,ReservationHeld=retry&&receipt.ReservationHeld,Counted=receipt.Counted||success};
            var writes=new List<StoreMutation>{StoreMutation.Condition(active!.Pk,active.Sk,active.Version),StoreMutation.Condition(groupRow!.Pk,groupRow.Sk,groupRow.Version)};
            if(!retry)writes.AddRange(await quotas.ReleaseAsync(receipt,success,ct));
            if(receipt.State=="processing") writes.AddRange(await budget.OutcomeAsync(error is "scan_timeout" or "scan_provider_unavailable" or "scan_interrupted" or "scan_rate_limited" or "scan_provider_error" or "receipt_provider_timeout" or "receipt_provider_unavailable" or "receipt_provider_rate_limited",ct));
            if(success)
            {
                writes.AddRange(ReceiptDocuments.Create(receipt.Id,$"SCAN#{receipt.Generation:D4}",extraction!));
                var eventId=Ids.New();writes.Add(StoreMutation.Put(StoreRow.Create("OUTBOX",eventId,1,new{id=eventId,groupId=receipt.GroupId,kind="receipt_ready",actorId="system",description="Receipt ready to review",createdAt=DateTimeOffset.UtcNow,entityId=receipt.Id,recipientParticipantIds=new[]{receipt.UploaderParticipantId}}),null));
            }
            if(state=="not_bill")
            {
                next=next with{ImagesRemoved=true,PurgeAt=DateTimeOffset.UtcNow.AddHours(1)};var purge=await store.GetAsync("WORK#receipt-purge",receipt.Id,ct);
                writes.Add(StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",receipt.Id,(purge?.Version??0)+1,new ReceiptWork(receipt.Id,next.PurgeAt.Value)),purge?.Version));
            }
            writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,next.Version,next),row.Version));
            var currentWork=await store.GetAsync(work.Pk,work.Sk,ct);if(currentWork is not null)
                writes.Add(retry?StoreMutation.Put(StoreRow.Create(work.Pk,work.Sk,currentWork.Version+1,new ReceiptWork(receipt.Id,DateTimeOffset.UtcNow.AddSeconds(2))),currentWork.Version):StoreMutation.Delete(work.Pk,work.Sk,currentWork.Version));
            try{await store.TransactAsync(writes,ct);return;}catch(StoreConflictException)when(attempt<4){}
        }
    }
    private async Task DeleteWorkAsync(StoreRow work,CancellationToken ct)
    {try{await store.TransactAsync([StoreMutation.Delete(work.Pk,work.Sk,work.Version)],ct);}catch(StoreConflictException){}}
}
