namespace Hisaab.Api.Identity;

public sealed record AccountDeletionState(string UserId, DateTimeOffset RequestedAt,
    DateTimeOffset Deadline, IReadOnlyList<string>? RevokedProviders = null,
    bool RevenueCatDeleted = false);
