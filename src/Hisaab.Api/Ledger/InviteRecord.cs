namespace Hisaab.Api.Ledger;

public sealed record InviteRecord(string GroupId, string? ParticipantId, DateTimeOffset ExpiresAt, string CreatorId, DateTimeOffset? RevokedAt = null);
