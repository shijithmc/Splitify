namespace Hisaab.Api.Receipts;

public static class ReceiptDispatch
{
    // Round up: a retry wakeup must not be acknowledged before its durable due time.
    public static int DelaySeconds(DateTimeOffset dueAt, DateTimeOffset now) =>
        (int)Math.Clamp(Math.Ceiling((dueAt - now).TotalSeconds), 0, 900);
}
