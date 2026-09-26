namespace Hisaab.Api.Receipts;
public sealed record ReceiptCreateRequest(string Id, bool ScanRequested, IReadOnlyList<ReceiptUploadInput> Images);
