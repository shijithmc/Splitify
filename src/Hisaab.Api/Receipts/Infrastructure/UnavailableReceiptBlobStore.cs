using Hisaab.Domain;

namespace Hisaab.Api.Receipts.Infrastructure;

public sealed class UnavailableReceiptBlobStore : IReceiptBlobStore
{
    private static DomainException Error() => new(503, "receipt_storage_unconfigured", "Receipt storage is unavailable. You can still enter an expense manually.");
    public Task<ReceiptUploadGrant> CreateUploadAsync(ReceiptUploadSlot slot, CancellationToken ct = default) => throw Error();
    public Task<IReadOnlyList<ReceiptMedia>> ValidateAsync(string receiptId, IReadOnlyList<ReceiptUploadSlot> slots, CancellationToken ct = default) => throw Error();
    public Task<byte[]> ReadAsync(ReceiptMedia media, bool thumbnail, long offset, int length, CancellationToken ct = default) => throw Error();
    public Task DeleteAsync(string receiptId, CancellationToken ct = default) => throw Error();
}
