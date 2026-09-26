namespace Hisaab.Api.Receipts;
public sealed record ReceiptRecord(string Id, string GroupId, string? UploaderId, string UploaderParticipantId,
    string State, bool ScanRequested, IReadOnlyList<ReceiptUploadSlot> Uploads, IReadOnlyList<ReceiptMedia> Media,
    DateTimeOffset CreatedAt, DateTimeOffset ExpiresAt, long Version = 1, string? QuotaMonth = null,
    bool ReservationHeld = false, bool Counted = false, int Attempts = 0, int Generation = 0,
    string? LeaseToken = null, DateTimeOffset? LeaseUntil = null, string? ErrorCode = null,
    string? ExpenseId = null, long Revision = 0, bool ImagesRemoved = false, DateTimeOffset? PurgeAt = null,
    string? RevisionHash = null);
