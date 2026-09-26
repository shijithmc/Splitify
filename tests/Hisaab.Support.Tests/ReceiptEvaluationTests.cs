using Hisaab.ReceiptEval;
namespace Hisaab.Support.Tests;

public sealed class ReceiptEvaluationTests
{
    [Fact]
    public void FailedReadsStayInAccuracyDenominatorAndNegativeExamplesStaySeparate()
    {
        var report = EvaluationSummary.From([
            new("grocery", "Devanagari", true, true, true, true, false, 500, 100, 40, 20, false),
            new("grocery", "Devanagari", true, false, false, false, false, 20000, null, null, null, true),
            new("negative", "none", false, true, false, false, true, 700, 50, 20, 10, false)
        ]);
        Assert.Equal(.5m, report.ReadingRate);
        Assert.Equal(.5m, report.TotalAndTaxExactRate);
        Assert.Equal(1, report.FalsePositives);
        Assert.Equal(700, report.P50Milliseconds);
        Assert.Equal(20000, report.P95Milliseconds);
        Assert.Equal(150, report.InputTokens);
        Assert.Equal(1, report.MissingUsage);
    }
    [Fact]
    public void EmptySetNeverClaimsPerfectAccuracy()
    {
        var report = EvaluationSummary.From([]);
        Assert.Null(report.ReadingRate);
        Assert.Null(report.TotalAndTaxExactRate);
        Assert.Equal(0, report.P95Milliseconds);
    }
}
