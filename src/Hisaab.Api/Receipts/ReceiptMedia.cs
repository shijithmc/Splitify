namespace Hisaab.Api.Receipts;
public sealed record ReceiptMedia(string Id, string Key, string ThumbnailKey, string ContentType, long SizeBytes, string Sha256, int Width, int Height, long ThumbnailSizeBytes);
