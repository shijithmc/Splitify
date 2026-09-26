namespace Hisaab.Api.Identity;

public sealed record UserAccount(string Id, string DisplayName, string? Email, string Status, DateTimeOffset CreatedAt);
