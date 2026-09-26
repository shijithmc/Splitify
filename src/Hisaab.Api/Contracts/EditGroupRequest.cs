namespace Hisaab.Api.Contracts;

public sealed record EditGroupRequest(long Version, string? Name = null, bool? Archived = null);
