namespace Hisaab.Api.Identity;

public sealed record Actor(UserAccount User, long AccountVersion, string SessionHash, long SessionVersion, DateTimeOffset AuthenticatedAt);
