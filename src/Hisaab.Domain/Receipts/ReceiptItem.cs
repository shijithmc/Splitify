namespace Hisaab.Domain.Receipts;

public sealed record ReceiptItem(string Id, string Name, string Quantity, long UnitPricePaise,
    long LineTotalPaise, IReadOnlyList<string> AssigneeIds, bool Ignored = false,
    decimal? Confidence = null, string? Transliteration = null,
    string? SourceUnitPrice = null, string? SourceLineTotal = null);
