namespace Hisaab.Domain.Receipts;

public sealed record ReceiptPreview(string ReviewHash, long ItemSubtotalPaise,
    long AdditiveChargesPaise, long DifferencePaise, bool RequiresDifferenceAcknowledgement,
    IReadOnlyDictionary<string, long> Shares, IReadOnlyList<ReceiptPerson> People,
    IReadOnlyList<string> Warnings, string? SourceDifference = null);
