namespace Hisaab.ReceiptEval;

public sealed record EvaluationSummary(int Cases, int Bills, int Readings, decimal? ReadingRate, decimal? TotalAndTaxExactRate, decimal? ItemsExactRate, int NonBills, int FalsePositives, int ProviderErrors, long P50Milliseconds, long P90Milliseconds, long P95Milliseconds, long InputTokens, long OutputTokens, long ThinkingTokens, int MissingUsage)
{
    public static EvaluationSummary From(IReadOnlyList<EvaluationResult> rows)
    {
        var bills = rows.Count(r => r.IsBill);
        decimal? Rate(int n) => bills == 0 ? null : (decimal)n / bills;
        var times = rows.Select(r => r.ElapsedMs).Order().ToArray();
        long Percentile(decimal p) => times.Length == 0 ? 0 : times[(int)decimal.Ceiling(times.Length * p) - 1];
        return new(rows.Count, bills, rows.Count(r => r.IsBill && r.Read), Rate(rows.Count(r => r.IsBill && r.Read)),
            Rate(rows.Count(r => r.IsBill && r.TotalAndTaxExact)), Rate(rows.Count(r => r.IsBill && r.ItemsExact)),
            rows.Count - bills, rows.Count(r => r.FalsePositive), rows.Count(r => r.ProviderError), Percentile(.5m), Percentile(.9m), Percentile(.95m),
            rows.Sum(r => r.InputTokens ?? 0), rows.Sum(r => r.OutputTokens ?? 0), rows.Sum(r => r.ThinkingTokens ?? 0), rows.Count(r => r.InputTokens is null));
    }
}
