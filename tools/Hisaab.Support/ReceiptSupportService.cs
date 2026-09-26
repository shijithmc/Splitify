using Hisaab.Api.Receipts;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
namespace Hisaab.Support;

public sealed class ReceiptSupportService(IAtomicStore store)
{
    public async Task<ReceiptSupportResult?> LookupAsync(string receiptId,string ticket,string operatorId,CancellationToken ct=default)
    {
        if(!Guid.TryParseExact(receiptId,"D",out _))throw new ArgumentException("RECEIPT_UUID must be a receipt UUID.");ValidateAudit(ticket,operatorId);
        var row=await store.GetAsync($"RECEIPT#{receiptId}","META",ct);
        var record=row?.Deserialize<ReceiptRecord>();
        await store.TransactAsync([Audit("lookup-scan",receiptId,ticket,operatorId)],ct);
        return record is null?null:new(record.Id,record.State,record.Version,record.CreatedAt,record.ExpiresAt,record.Attempts,record.ErrorCode,record.ReservationHeld,record.Counted,record.ImagesRemoved,record.PurgeAt,record.LeaseUntil,record.ExpenseId is not null,record.Media.Count);
    }
    public async Task<ReceiptRuntimeControl> ControlAsync(string mode,string ticket,string operatorId,bool confirmed,CancellationToken ct=default)
    {
        ValidateAudit(ticket,operatorId);if(!confirmed)throw new ArgumentException("--confirm is required for runtime control changes.");
        if(mode is not("stop" or "pause-free" or "resume"))throw new ArgumentException("Control must be stop, pause-free or resume.");
        for(var attempt=0;attempt<5;attempt++)
        {
            var row=await store.GetAsync("OPERATIONS","RECEIPTS",ct);var current=row?.Deserialize<ReceiptRuntimeControl>()??new();
            // pause-free never clears a previously activated emergency stop.
            var next=mode switch{"stop"=>current with{EmergencyStop=true},"pause-free"=>current with{PauseFree=true},_=>new ReceiptRuntimeControl()};
            try{await store.TransactAsync([StoreMutation.Put(StoreRow.Create("OPERATIONS","RECEIPTS",(row?.Version??0)+1,next),row?.Version),Audit("receipt-control:"+mode,"receipts",ticket,operatorId)],ct);return next;}
            catch(StoreConflictException)when(attempt<4){}
        }
        throw new InvalidOperationException("Receipt runtime control changed concurrently. Retry.");
    }
    private static StoreMutation Audit(string action,string entity,string ticket,string operatorId)
    {
        var now=DateTimeOffset.UtcNow;return StoreMutation.Put(StoreRow.Create("SUPPORT_AUDIT",$"{now:O}#{Ids.New()}",1,new{action,entity,ticket,operatorId,createdAt=now}),null);
    }
    private static void ValidateAudit(string ticket,string operatorId)
    {
        if(string.IsNullOrWhiteSpace(ticket)||ticket.Length>200||ticket.Any(char.IsControl)||string.IsNullOrWhiteSpace(operatorId)||operatorId.Length>200||operatorId.Any(char.IsControl))
            throw new ArgumentException("TICKET and OPERATOR require 1–200 characters without control characters.");
    }
}
