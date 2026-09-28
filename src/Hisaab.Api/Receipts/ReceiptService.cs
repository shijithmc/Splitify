using System.Text.Json;
using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptService(IAtomicStore store, CommandExecutor commands, ReceiptAccess access,
    ReceiptQuotaService quotas, ReceiptDocuments documents, IReceiptBlobStore blobs, ReceiptAttachmentService attachments, IConfiguration config)
{
    public async Task<object> AllowanceAsync(Actor actor,CancellationToken ct)
    { await access.EnsureSessionAsync(actor,ct); throw ScanningRemoved(); }
    public async Task<JsonElement> ConsentAsync(Actor actor,string key,ReceiptConsentRequest input,CancellationToken ct)
    { await access.EnsureSessionAsync(actor,ct); throw ScanningRemoved(); }
    private static DomainException ScanningRemoved()=>new(410,"ai_scanning_removed","AI bill scanning has been removed. Attach a receipt and enter the details manually.");
    public async Task<object> CreateAsync(Actor actor,string key,string groupId,ReceiptCreateRequest input,CancellationToken ct)
    {
        await access.EnsureSessionAsync(actor,ct);
        if(input.ScanRequested)throw ScanningRemoved();
        await access.GroupAsync(groupId,actor.User.Id,ct);
        if(!Guid.TryParseExact(input.Id,"D",out _)||input.Images is null||input.Images.Count is <1 or >3)throw new DomainException(422,"receipt_images_invalid","Choose one to three receipt images.");
        if(input.Images.Select(x=>x.Id).Distinct(StringComparer.Ordinal).Count()!=input.Images.Count)throw new DomainException(422,"receipt_images_invalid","Each image needs its own ID.");
        foreach(var image in input.Images)
            if(!Guid.TryParseExact(image.Id,"D",out _)||image.ContentType is not("image/jpeg" or "image/png")||image.SizeBytes is <1 or >10*1024*1024||image.Sha256 is null||image.Sha256.Length!=64||image.Sha256.Any(c=>!Uri.IsHexDigit(c)))
                throw new DomainException(422,"receipt_images_invalid","Use JPEG or PNG images up to 10 MB with a SHA-256 checksum.");
        await commands.ExecuteAsync(actor,key,$"receipts:create:{groupId}",input,async()=>
        {
            var groupRow=await access.GroupAsync(groupId,actor.User.Id,ct);var group=groupRow.Deserialize<Group>();GroupRules.EnsureWritable(group);
            var existingRow=await store.GetAsync($"RECEIPT#{input.Id}","META",ct);
            if(existingRow is not null)
            {
                var existing=existingRow.Deserialize<ReceiptRecord>();
                // A saved draft from an older app keeps its ID and images when switching to manual entry.
                var matchingImages=existing.Uploads.Select(x=>new ReceiptUploadInput(x.Id,x.ContentType,x.SizeBytes,x.Sha256)).SequenceEqual(input.Images.Select(x=>x with{Sha256=x.Sha256.ToLowerInvariant()}));
                if(!existing.ScanRequested||existing.UploaderId!=actor.User.Id||existing.GroupId!=groupId||existing.ExpenseId is not null||existing.ImagesRemoved||existing.ExpiresAt<=DateTimeOffset.UtcNow||existing.State is not("awaiting_upload" or "validating" or "queued" or "processing" or "ready" or "manual_ready")||!matchingImages)
                    throw new DomainException(409,"receipt_exists","This receipt already exists.");
                var migrated=existing with{ScanRequested=false,Version=existing.Version+1};
                return new(new{existing.Id},[StoreMutation.Condition(groupRow.Pk,groupRow.Sk,groupRow.Version),StoreMutation.Put(StoreRow.Create(existingRow.Pk,existingRow.Sk,migrated.Version,migrated),existingRow.Version)]);
            }
            var now=DateTimeOffset.UtcNow;var receipt=new ReceiptRecord(input.Id,groupId,actor.User.Id,group.Members.Single(m=>m.UserId==actor.User.Id&&!m.HasLeft&&!m.IsDeleted).Id,
                "awaiting_upload",false,input.Images.Select(x=>new ReceiptUploadSlot(x.Id,$"quarantine/{input.Id}/{x.Id}",x.ContentType,x.SizeBytes,x.Sha256.ToLowerInvariant())).ToArray(),[],now,now.AddDays(1));
            return new(new {receipt.Id},[
                await new ReceiptUploadAdmission(store,config).ReserveAsync(receipt,ct),
                StoreMutation.Condition(groupRow.Pk,groupRow.Sk,groupRow.Version),
                StoreMutation.Put(StoreRow.Create($"RECEIPT#{receipt.Id}","META",1,receipt),null),
                StoreMutation.Put(StoreRow.Create($"USER#{actor.User.Id}",$"RECEIPT#{receipt.Id}",1,new {receiptId=receipt.Id}),null),
                StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",receipt.Id,1,new ReceiptWork(receipt.Id,receipt.ExpiresAt)),null)]);
        },ct);
        var saved=(await access.ReceiptAsync(actor,input.Id,true,ct)).Deserialize<ReceiptRecord>();
        var grants=saved.State=="awaiting_upload"?await Task.WhenAll(saved.Uploads.Select(s=>blobs.CreateUploadAsync(s,ct))):[];
        return new {receipt=await GetAsync(actor,saved.Id,ct),uploads=grants};
    }
    public async Task<ReceiptUploadSlot> AuthorizeUploadAsync(Actor actor,string receiptId,string imageId,CancellationToken ct=default)
    {
        var receipt=(await access.ReceiptAsync(actor,receiptId,true,ct)).Deserialize<ReceiptRecord>();
        if(receipt.State!="awaiting_upload"||receipt.ExpiresAt<=DateTimeOffset.UtcNow)throw ReceiptAccess.Missing();
        return receipt.Uploads.SingleOrDefault(x=>x.Id==imageId)??throw ReceiptAccess.Missing();
    }
    public async Task<JsonElement> CompleteAsync(Actor actor,string key,string id,ReceiptVersionRequest input,CancellationToken ct)
    {
        await access.ReceiptAsync(actor,id,true,ct);
        return await commands.ExecuteAsync(actor,key,$"receipts:complete:{id}",input,async()=>
        {
            var row=await access.ReceiptAsync(actor,id,true,ct);var receipt=row.Deserialize<ReceiptRecord>();ReceiptAccess.Version(receipt,input.Version);
            if(receipt.State!="awaiting_upload"||receipt.ExpiresAt<=DateTimeOffset.UtcNow)throw new DomainException(409,"receipt_state_invalid","This upload is already sealed or expired.");
            var updated=receipt with{State="validating",ScanRequested=false,Version=receipt.Version+1,Generation=receipt.Generation+1};
            return new(new{updated.Id,updated.State,updated.Version},[StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,updated.Version,updated),row.Version),StoreMutation.Put(StoreRow.Create("WORK#receipt-scan",id,1,new ReceiptWork(id,DateTimeOffset.UtcNow)),null)]);
        },ct);
    }
    public async Task<object> GetAsync(Actor actor,string id,CancellationToken ct)
    {
        var receipt=(await access.ReceiptAsync(actor,id,false,ct)).Deserialize<ReceiptRecord>();
        var extraction=receipt.Counted&&receipt.ExpenseId is null?await documents.ReadAsync(id,$"SCAN#{receipt.Generation:D4}",ct):null;
        var review=receipt.Revision>0?await attachments.ReadRevisionAsync(id,receipt.Revision,ct):null;
        await access.ReceiptAsync(actor,id,false,ct);
        return new{receipt.Id,receipt.GroupId,receipt.State,receipt.Version,receipt.Attempts,receipt.ErrorCode,receipt.ImagesRemoved,receipt.ExpenseId,receipt.Revision,receipt.RevisionHash,receipt.ExpiresAt,review,manualAvailable=receipt.Media.Count>0&&!receipt.ImagesRemoved&&receipt.State!="not_bill",
            media=receipt.ImagesRemoved?[]:receipt.Media.Select(x=>new{x.Id,x.ContentType,x.SizeBytes,x.Width,x.Height,x.ThumbnailSizeBytes}).ToArray(),extraction};
    }
    public async Task<JsonElement> RetryAsync(Actor actor,string key,string id,ReceiptVersionRequest input,CancellationToken ct)
    { await access.EnsureSessionAsync(actor,ct); throw ScanningRemoved(); }
    public async Task<object> TicketAsync(Actor actor,string id,CancellationToken ct)
    {
        var receipt=(await access.ReceiptAsync(actor,id,false,ct)).Deserialize<ReceiptRecord>();
        if(receipt.ImagesRemoved||receipt.Media.Count==0||receipt.State=="not_bill"||!await MediaVisibleAsync(receipt,ct))throw ReceiptAccess.Missing();
        var token=Ids.Token();var expires=DateTimeOffset.UtcNow.AddMinutes(10);
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create($"RECEIPTMEDIA#{Ids.Hash(token)}","META",1,new ReceiptMediaTicket(id,actor.User.Id,actor.SessionHash,expires),expires.ToUnixTimeSeconds()),null)],ct);
        return new{ticket=token,expiresAt=expires};
    }
    public async Task<(byte[] Bytes,string ContentType)> MediaAsync(Actor actor,string id,string mediaId,string ticket,bool thumbnail,long offset,int length,CancellationToken ct)
    {
        var receipt=(await access.ReceiptAsync(actor,id,false,ct)).Deserialize<ReceiptRecord>();
        if(receipt.ImagesRemoved||receipt.State=="not_bill"||!await MediaVisibleAsync(receipt,ct)||string.IsNullOrWhiteSpace(ticket)||ticket.Length!=64)throw ReceiptAccess.Missing();
        var authorization=(await store.GetAsync($"RECEIPTMEDIA#{Ids.Hash(ticket)}","META",ct))?.Deserialize<ReceiptMediaTicket>();
        if(authorization is null||authorization.ReceiptId!=id||authorization.UserId!=actor.User.Id||authorization.SessionHash!=actor.SessionHash||authorization.ExpiresAt<=DateTimeOffset.UtcNow)throw ReceiptAccess.Missing();
        var media=receipt.Media.SingleOrDefault(m=>m.Id==mediaId)??throw ReceiptAccess.Missing();var size=thumbnail?media.ThumbnailSizeBytes:media.SizeBytes;
        if(offset<0||offset>=size||length is<1 or>1048576)throw new DomainException(416,"receipt_range_invalid","Request an image chunk of at most 1 MiB.");
        var admittedLength=(int)Math.Min(length,size-offset);
        await new ReceiptDownloadAdmission(store,config).AdmitAsync(actor,admittedLength,ct);
        var bytes=await blobs.ReadAsync(media,thumbnail,offset,admittedLength,ct);
        var latest=(await access.ReceiptAsync(actor,id,false,ct)).Deserialize<ReceiptRecord>();if(latest.ImagesRemoved||latest.State=="not_bill"||!await MediaVisibleAsync(latest,ct))throw ReceiptAccess.Missing();
        return(bytes,thumbnail?"image/jpeg":media.ContentType);
    }
    public async Task<JsonElement> RemoveImagesAsync(Actor actor,string key,string id,ReceiptVersionRequest input,CancellationToken ct)
    {
        await access.ReceiptAsync(actor,id,false,ct);
        return await commands.ExecuteAsync(actor,key,$"receipts:remove:{id}",input,async()=>
        {
            var row=await access.ReceiptAsync(actor,id,false,ct);var receipt=row.Deserialize<ReceiptRecord>();ReceiptAccess.Version(receipt,input.Version);
            var next=receipt with{ImagesRemoved=true,PurgeAt=DateTimeOffset.UtcNow,ReservationHeld=false,LeaseToken=null,LeaseUntil=null,Generation=receipt.Generation+1,State=receipt.ExpenseId is null?"cancelled":"attached",Version=receipt.Version+1};
            var writes=(await quotas.ReleaseAsync(receipt,false,ct)).ToList();writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,next.Version,next),row.Version));
            var purge=await store.GetAsync("WORK#receipt-purge",id,ct);writes.Add(StoreMutation.Put(StoreRow.Create("WORK#receipt-purge",id,(purge?.Version??0)+1,new ReceiptWork(id,DateTimeOffset.UtcNow.AddMinutes(10))),purge?.Version));
            var groupRow=await access.GroupAsync(receipt.GroupId,actor.User.Id,ct);var group=groupRow.Deserialize<Group>();var updated=group with{Version=group.Version+1};writes.Add(StoreMutation.Put(StoreRow.Create(groupRow.Pk,groupRow.Sk,updated.Version,updated),groupRow.Version));AddEvent(writes,updated,actor.User.Id,"receipt_images_removed",receipt.ExpenseId??id,null);
            return new(new{next.Id,next.Version,next.ImagesRemoved},writes);
        },ct);
    }
    public async Task<JsonElement> FlagAsync(Actor actor,string key,string groupId,string expenseId,ReceiptFlagRequest input,CancellationToken ct)
    {
        await access.EnsureSessionAsync(actor,ct);await access.GroupAsync(groupId,actor.User.Id,ct);
        if(input.Reason is not("total" or "items" or "image" or "other"))throw new DomainException(422,"receipt_flag_invalid","Choose a mismatch reason.");
        return await commands.ExecuteAsync(actor,key,$"receipts:flag:{groupId}:{expenseId}",input,async()=>
        {
            var groupRow=await access.GroupAsync(groupId,actor.User.Id,ct);var group=groupRow.Deserialize<Group>();var expenseRow=await store.GetAsync(groupRow.Pk,$"EXPENSE#{expenseId}",ct)??throw ReceiptAccess.Missing();var expense=expenseRow.Deserialize<Expense>();
            var member=group.Members.Single(m=>m.UserId==actor.User.Id&&!m.HasLeft&&!m.IsDeleted);
            if(expense.DeletedAt is not null||!expense.Participants.Any(p=>p.ParticipantId==member.Id)&&expense.PayerId!=member.Id)throw ReceiptAccess.Missing();
            if(!expenseRow.Data.TryGetProperty("receiptId",out var receiptId)||receiptId.ValueKind!=JsonValueKind.String)throw ReceiptAccess.Missing();
            var sk=$"RECEIPTFLAG#{expenseId}#{actor.User.Id}";var prior=await store.GetAsync(groupRow.Pk,sk,ct);if(prior is not null)return new(new{flagged=true},[StoreMutation.Condition(groupRow.Pk,groupRow.Sk,groupRow.Version)]);
            var updated=group with{Version=group.Version+1};var writes=new List<StoreMutation>{StoreMutation.Put(StoreRow.Create(groupRow.Pk,groupRow.Sk,updated.Version,updated),groupRow.Version),StoreMutation.Condition(expenseRow.Pk,expenseRow.Sk,expenseRow.Version),StoreMutation.Put(StoreRow.Create(groupRow.Pk,sk,1,new{expenseId,input.Reason,participantId=member.Id,createdAt=DateTimeOffset.UtcNow}),null)};
            AddEvent(writes,updated,actor.User.Id,"receipt_mismatch",expenseId,[expense.PayerId]);return new(new{flagged=true},writes);
        },ct);
    }
    public async Task<object> DuplicatesAsync(Actor actor,string id,Hisaab.Domain.Receipts.ReceiptReview review,CancellationToken ct)
    {
        var receipt=(await access.ReceiptAsync(actor,id,false,ct)).Deserialize<ReceiptRecord>();
        var matches=await store.QueryAsync($"GROUP#{receipt.GroupId}",ReceiptFingerprint.Prefix(review,config),100,ct:ct);
        var result=new List<object>();
        foreach(var row in matches.Items)
        {
            var match=row.Deserialize<ReceiptDuplicate>();if(match.CreatedAt<DateTimeOffset.UtcNow.AddDays(-7)||match.ReceiptId==id)continue;
            var expense=(await store.GetAsync($"GROUP#{receipt.GroupId}",$"EXPENSE#{match.ExpenseId}",ct))?.Deserialize<Expense>();
            if(expense is not null&&expense.DeletedAt is null)result.Add(new{match.ExpenseId,match.ReceiptId,match.AddedBy,match.CreatedAt});
        }
        await access.ReceiptAsync(actor,id,false,ct);return new{items=result};
    }
    private async Task<bool> MediaVisibleAsync(ReceiptRecord receipt,CancellationToken ct)
    {
        if(receipt.ExpenseId is null)return true;
        var expense=(await store.GetAsync($"GROUP#{receipt.GroupId}",$"EXPENSE#{receipt.ExpenseId}",ct))?.Deserialize<Expense>();
        return expense is not null&&expense.DeletedAt is null;
    }
    internal static void AddEvent(List<StoreMutation> writes,Group group,string actorId,string kind,string entityId,string[]? recipients)
    {
        var id=Ids.New();var payload=new{id,groupId=group.Id,kind,actorId,description=kind.Replace('_',' '),createdAt=DateTimeOffset.UtcNow,entityId,recipientParticipantIds=recipients};
        writes.Add(StoreMutation.Put(StoreRow.Create($"GROUP#{group.Id}",$"EVENT#{long.MaxValue-group.Version:D19}#{id}",1,payload),null));writes.Add(StoreMutation.Put(StoreRow.Create("OUTBOX",id,1,payload),null));
    }
}
