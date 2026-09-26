using Hisaab.Domain;

namespace Hisaab.Api.Ledger;

public sealed record MemberDetail(string Id, string? UserId, string DisplayName, bool IsPlaceholder,
    bool IsExternal, bool IsDeleted, bool HasLeft, DateTimeOffset? CreatedAt, bool ExternalReviewDue)
{
    public static MemberDetail From(Member member, DateTimeOffset now) => new(member.Id, member.UserId,
        member.DisplayName, member.IsPlaceholder, member.IsExternal, member.IsDeleted, member.HasLeft,
        member.CreatedAt, member.UserId is null && member.IsPlaceholder && !member.IsExternal && !member.IsDeleted &&
        !member.HasLeft && member.CreatedAt is { } created && created <= now.AddDays(-90));
}
