namespace Hisaab.Domain;

public sealed record Expense(string Id, string GroupId, string Description, long AmountPaise,
    DateOnly Date, string PayerId, SplitMode Mode, IReadOnlyList<SplitParticipant> Participants,
    IReadOnlyDictionary<string, long> Shares, long Version, DateTimeOffset? DeletedAt,
    string CreatedBy, DateTimeOffset UpdatedAt);
