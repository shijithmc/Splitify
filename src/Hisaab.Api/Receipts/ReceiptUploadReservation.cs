namespace Hisaab.Api.Receipts;
public sealed record ReceiptUploadReservation(string ReceiptId,long Bytes,DateTimeOffset ExpiresAt);
