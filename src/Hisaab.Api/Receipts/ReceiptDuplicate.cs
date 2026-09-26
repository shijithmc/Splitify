namespace Hisaab.Api.Receipts;

public sealed record ReceiptDuplicate(string ExpenseId, string ReceiptId, DateTimeOffset CreatedAt, string AddedBy);
