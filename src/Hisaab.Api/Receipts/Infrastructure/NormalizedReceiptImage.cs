namespace Hisaab.Api.Receipts.Infrastructure;

public sealed record NormalizedReceiptImage(byte[] Image, byte[] Thumbnail, int Width, int Height);
