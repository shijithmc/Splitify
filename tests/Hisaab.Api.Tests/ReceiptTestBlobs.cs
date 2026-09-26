using Hisaab.Api.Receipts;
namespace Hisaab.Api.Tests;
internal sealed class ReceiptTestBlobs : IReceiptBlobStore
{
    public List<string> Deleted { get; }=[];
    public Task<ReceiptUploadGrant> CreateUploadAsync(ReceiptUploadSlot slot,CancellationToken ct=default)=>Task.FromResult(new ReceiptUploadGrant(slot.Id,"https://upload.invalid/"+slot.Id,"PUT",new Dictionary<string,string>(),DateTimeOffset.UtcNow.AddMinutes(10)));
    public Task<IReadOnlyList<ReceiptMedia>> ValidateAsync(string id,IReadOnlyList<ReceiptUploadSlot> slots,CancellationToken ct=default)=>Task.FromResult<IReadOnlyList<ReceiptMedia>>(slots.Select(s=>new ReceiptMedia(s.Id,"images/"+id+"/"+s.Id,"thumbs/"+id+"/"+s.Id,"image/jpeg",10,s.Sha256,100,100,3)).ToArray());
    public Task<byte[]> ReadAsync(ReceiptMedia media,bool thumbnail,long offset,int length,CancellationToken ct=default)=>Task.FromResult(new byte[length]);
    public Task DeleteAsync(string id,CancellationToken ct=default){Deleted.Add(id);return Task.CompletedTask;}
}
