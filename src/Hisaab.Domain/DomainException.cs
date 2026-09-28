namespace Hisaab.Domain;

public sealed class DomainException(int status, string code, string message, int? retryAfterSeconds = null) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
    public int? RetryAfterSeconds { get; } = retryAfterSeconds;
}
