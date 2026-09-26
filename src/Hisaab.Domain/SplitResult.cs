namespace Hisaab.Domain;

public sealed record SplitResult(IReadOnlyDictionary<string, long> Shares,
    IReadOnlyList<string> RoundingOrder);
