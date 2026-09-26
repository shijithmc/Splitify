namespace Hisaab.Support;
public sealed record ReceiptSupportResult(string ReceiptId,string State,long Version,DateTimeOffset CreatedAt,
    DateTimeOffset ExpiresAt,int Attempts,string? ErrorCode,bool ReservationHeld,bool Counted,bool ImagesRemoved,
    DateTimeOffset? PurgeAt,DateTimeOffset? LeaseUntil,bool Attached,int ImageCount);
