namespace Hisaab.Api.Receipts;
public sealed record ReceiptConsent(string Version, bool Accepted, DateTimeOffset AcceptedAt);
