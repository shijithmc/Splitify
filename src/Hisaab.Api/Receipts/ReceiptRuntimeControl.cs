namespace Hisaab.Api.Receipts;
public sealed record ReceiptRuntimeControl(bool EmergencyStop = false, bool PauseFree = false);
