namespace Hisaab.Api.Receipts;
public sealed class ReceiptProviderException(string code, bool transient) : Exception(code)
{
    public string Code { get; } = code;
    public bool Transient { get; } = transient;
}
