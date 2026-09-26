namespace Hisaab.Api.Receipts;

public sealed record ReceiptRevisionManifest(long Revision, int Pages, int Bytes, string ContentHash);
