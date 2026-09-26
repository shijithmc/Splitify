namespace Hisaab.Api.Receipts;
public interface IReceiptBlobStore
{
    Task<ReceiptUploadGrant> CreateUploadAsync(ReceiptUploadSlot slot, CancellationToken ct = default);
    Task<IReadOnlyList<ReceiptMedia>> ValidateAsync(string receiptId, IReadOnlyList<ReceiptUploadSlot> slots, CancellationToken ct = default);
    Task<byte[]> ReadAsync(ReceiptMedia media, bool thumbnail, long offset, int length, CancellationToken ct = default);
    Task DeleteAsync(string receiptId, CancellationToken ct = default);
}
