namespace Hisaab.Api.Receipts;
public sealed record ReceiptBudget(long ReservedMicrousd, int Attempts, int ConsecutiveFailures = 0, DateTimeOffset? CircuitUntil = null, bool Alarm80 = false);
