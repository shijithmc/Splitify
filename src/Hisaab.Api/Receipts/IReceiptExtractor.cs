namespace Hisaab.Api.Receipts;
public interface IReceiptExtractor
{
    Task<ReceiptExtraction> ExtractAsync(IReadOnlyList<ReceiptMedia> media, CancellationToken ct = default);
}
