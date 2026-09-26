namespace Hisaab.Domain.Receipts;

public sealed record ReceiptComponent(string Id, long AmountPaise,
    string Kind = "Item", bool IncludedInItemPrices = false);
