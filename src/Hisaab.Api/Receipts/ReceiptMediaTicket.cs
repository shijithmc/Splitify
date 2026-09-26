namespace Hisaab.Api.Receipts;
public sealed record ReceiptMediaTicket(string ReceiptId, string UserId, string SessionHash, DateTimeOffset ExpiresAt);
