namespace Hisaab.ReceiptEval;

public sealed record EvaluationResult(string Category, string Script, bool IsBill, bool Read, bool TotalAndTaxExact, bool ItemsExact, bool FalsePositive, long ElapsedMs, long? InputTokens, long? OutputTokens, long? ThinkingTokens, bool ProviderError);
