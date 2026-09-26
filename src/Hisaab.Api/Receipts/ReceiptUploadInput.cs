namespace Hisaab.Api.Receipts;
public sealed record ReceiptUploadInput(string Id, string ContentType, long SizeBytes, string Sha256);
