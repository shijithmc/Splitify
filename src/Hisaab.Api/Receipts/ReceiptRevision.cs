using Hisaab.Domain.Receipts;
namespace Hisaab.Api.Receipts;

public sealed record ReceiptRevision(string ReceiptId, long Revision, ReceiptReview Review,
    IReadOnlyDictionary<string, long> Shares, string ReviewHash, DateTimeOffset ReviewedAt);
