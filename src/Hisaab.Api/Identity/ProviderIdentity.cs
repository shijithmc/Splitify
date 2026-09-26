namespace Hisaab.Api.Identity;

public sealed record ProviderIdentity(string UserId, string Provider, string Subject, string? Email, string? EncryptedRefreshToken, string Audience);
