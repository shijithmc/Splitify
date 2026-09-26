namespace Hisaab.Api.Receipts;
public sealed record ReceiptAdmission(IReadOnlyList<DateTimeOffset> Attempts);
