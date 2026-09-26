namespace Hisaab.Api.Receipts;
public sealed record ReceiptUploadSlot(string Id, string Key, string ContentType, long SizeBytes, string Sha256);
