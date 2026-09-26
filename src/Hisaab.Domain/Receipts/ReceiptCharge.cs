namespace Hisaab.Domain.Receipts;

public sealed record ReceiptCharge(string Id, string Name, string Kind, long AmountPaise,
    bool IncludedInItemPrices = false, IReadOnlyDictionary<string, long>? Weights = null,
    decimal? Confidence = null, string? SourceAmount = null);
