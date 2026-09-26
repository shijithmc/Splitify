using Hisaab.Api.Identity;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptDownloadAdmission(IAtomicStore store,IConfiguration config)
{
    public async Task AdmitAsync(Actor actor,int bytes,CancellationToken ct=default)
    {
        if(bytes is <1 or>1048576)throw new DomainException(416,"receipt_range_invalid","Request at most 1 MiB per image chunk.");
        var maximumBytes=config.GetValue<long?>("Hisaab:Receipts:MaxDownloadBytesPerHour")??300L*1024*1024;
        var maximumChunks=config.GetValue<int?>("Hisaab:Receipts:MaxDownloadChunksPerMinute")??60;
        for(var attempt=0;attempt<6;attempt++)
        {
            var now=DateTimeOffset.UtcNow;var minute=now.ToUnixTimeSeconds()/60;var pk=$"USER#{actor.User.Id}";
            var account=await store.GetAsync(pk,"PROFILE",ct);var session=await store.GetAsync($"SESSION#{actor.SessionHash}","META",ct);var sessionValue=session?.Deserialize<SessionRecord>();
            if(account?.Deserialize<UserAccount>().Status!="active"||sessionValue is null||sessionValue.UserId!=actor.User.Id||sessionValue.AccessExpiresAt<=now)
                throw new DomainException(401,"session_expired","Sign in again.");
            var row=await store.GetAsync(pk,"RECEIPT_DOWNLOAD_ADMISSION",ct);var usage=row?.Deserialize<ReceiptDownloadUsage>()??new([]);
            // Include the oldest partial minute conservatively: byte admission never
            // undercounts any part of the preceding hour, at a cost of up to 59s slack.
            var buckets=usage.Buckets.Where(b=>b.Minute>=minute-60).ToList();var current=buckets.SingleOrDefault(b=>b.Minute==minute)??new(minute,0,0);
            var used=buckets.Sum(b=>b.Bytes);
            if(maximumBytes<=0||maximumChunks<=0||current.Chunks>=maximumChunks||bytes>maximumBytes-used)
                throw new DomainException(429,"receipt_download_rate_limited","Receipt downloads are temporarily limited. Try again later.");
            buckets.RemoveAll(b=>b.Minute==minute);buckets.Add(current with{Bytes=checked(current.Bytes+bytes),Chunks=checked(current.Chunks+1)});
            try
            {
                await store.TransactAsync([
                    StoreMutation.Condition(account!.Pk,account.Sk,account.Version),
                    StoreMutation.Condition(session!.Pk,session.Sk,session.Version),
                    StoreMutation.Put(StoreRow.Create(pk,"RECEIPT_DOWNLOAD_ADMISSION",(row?.Version??0)+1,new ReceiptDownloadUsage(buckets),now.AddHours(2).ToUnixTimeSeconds()),row?.Version)
                ],ct);return;
            }
            catch(StoreConflictException)when(attempt<5){await Task.Delay(Random.Shared.Next(5,25),ct);}
        }
        throw new DomainException(409,"receipt_download_busy","Another image download is in progress. Retry shortly.");
    }
}
