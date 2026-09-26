namespace Hisaab.Api.Contracts;

public sealed record MemberRequest(string DisplayName, string? Email = null, string? Phone = null);
