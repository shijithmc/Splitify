namespace Hisaab.Domain.Receipts;

public sealed record ReceiptReview(string Merchant, DateOnly Date, string SourceCurrency,
    long GrandTotalPaise, IReadOnlyList<ReceiptItem> Items, IReadOnlyList<ReceiptCharge> Charges,
    bool SplitByItems = false, bool DifferenceAcknowledged = false,
    string? SourceGrandTotal = null, bool ConvertedToInr = false,
    string? AcknowledgedReviewHash = null, long? SubtotalPaise = null,
    string? SourceSubtotal = null);
