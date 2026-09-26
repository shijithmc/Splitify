using Hisaab.Api.Receipts;
namespace Hisaab.Api.Tests;

public sealed class ReceiptDispatchTests
{
    [Theory]
    [InlineData(-1, 0)]
    [InlineData(0, 0)]
    [InlineData(0.1, 1)]
    [InlineData(1.9, 2)]
    [InlineData(2000, 900)]
    public void WakeupCannotArriveBeforeRetryDueTime(double delay, int expected)
    {
        var now = DateTimeOffset.UtcNow;
        Assert.Equal(expected, ReceiptDispatch.DelaySeconds(now.AddSeconds(delay), now));
    }
}
