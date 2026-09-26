namespace Hisaab.Api.Receipts;
public sealed record ReceiptAllowance(string Plan, int Cap, int Used, int Reserved, int Remaining, DateTimeOffset ResetsAt, bool ScanAvailable, string? Reason, string ConsentVersion, bool ConsentAccepted);
