namespace Hisaab.Api.Identity;

public sealed record SessionRecord(string UserId, string RefreshHash, DateTimeOffset AccessExpiresAt, DateTimeOffset RefreshExpiresAt, DateTimeOffset CreatedAt, string? VerifiedInviteEmail = null);
