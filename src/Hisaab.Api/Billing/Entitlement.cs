namespace Hisaab.Api.Billing;

public sealed record Entitlement(bool AdFree, string Status, DateTimeOffset? ExpiresAt = null, string? Store = null, DateTimeOffset? VerifiedAt = null)
{
    public static Entitlement Free => new(false, "free");
    public Entitlement At(DateTimeOffset now) => ExpiresAt is not null && ExpiresAt <= now ? this with { AdFree = false, Status = "expired" } : this;
}
