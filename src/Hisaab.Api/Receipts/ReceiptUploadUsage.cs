namespace Hisaab.Api.Receipts;
public sealed record ReceiptUploadUsage(IReadOnlyList<DateTimeOffset> Attempts,IReadOnlyList<ReceiptUploadReservation> Reservations);
