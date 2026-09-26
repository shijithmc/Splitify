namespace Hisaab.Domain.Receipts;

public sealed record ReceiptPerson(string ParticipantId, long ItemsPaise, long TotalPaise,
    IReadOnlyList<ReceiptComponent> Items, IReadOnlyList<ReceiptComponent> Charges);
