namespace Hisaab.Domain;

public static class GroupRules
{
    public const int MaximumMembers = 50;
    public const int MaximumExpenses = 10_000;

    public static string ValidateName(string name)
    {
        var trimmed = name?.Trim() ?? "";
        if (trimmed.EnumerateRunes().Count() is < 1 or > 100)
            throw new DomainException(422, "invalid_name", "Name must contain between 1 and 100 Unicode characters.");
        return trimmed;
    }

    public static void ValidateRoster(Group group)
    {
        if (!Enum.IsDefined(group.Type))
            throw new DomainException(422, "invalid_group_type", "Choose a supported group type.");
        if (group.Members is null || group.Members.Count is < 1 or > MaximumMembers ||
            group.Members.Any(m => m is null || string.IsNullOrWhiteSpace(m.Id)) ||
            group.Members.Select(m => m.Id).Distinct(StringComparer.Ordinal).Count() != group.Members.Count)
            throw new DomainException(422, "invalid_roster", "A group must retain between 1 and 50 unique ledger identities.");
        if (group.Type == GroupType.Direct && group.Members.Count > 2)
            throw new DomainException(422, "direct_member_limit", "A direct friendship can contain only two participants.");
        if (group.Members.Where(m => m.UserId is not null).GroupBy(m => m.UserId, StringComparer.Ordinal).Any(g => g.Count() > 1))
            throw new DomainException(422, "duplicate_member", "An account can own only one ledger identity in a group.");
    }

    public static Member RequireActiveMember(Group group, string userId)
    {
        var member = group.Members.SingleOrDefault(m => m.UserId == userId && !m.HasLeft && !m.IsDeleted);
        return member ?? throw new DomainException(404, "group_not_found", "Group not found.");
    }

    public static void EnsureWritable(Group group)
    {
        if (group.Deleted) throw new DomainException(404, "group_not_found", "Group not found.");
        if (group.Archived) throw new DomainException(409, "group_archived", "Reopen this group before making changes.");
    }

    public static void EnsureCanAddMember(Group group)
    {
        EnsureWritable(group);
        ValidateRoster(group);
        if (group.Members.Count >= (group.Type == GroupType.Direct ? 2 : MaximumMembers))
            throw new DomainException(422, "member_limit", group.Type == GroupType.Direct
                ? "A direct friendship can contain only two participants."
                : "This group has reached the limit of 50 retained participants.");
    }

    public static void RequireVersion(long current, long expected)
    {
        if (current != expected)
            throw new DomainException(409, "version_conflict", "This item changed. Refresh and try again.");
    }

    public static void EnsureCanDelete(Group group, string userId, long expectedVersion,
        IReadOnlyList<Balance> balances)
    {
        if (group.Deleted) throw new DomainException(404, "group_not_found", "Group not found.");
        RequireVersion(group.Version, expectedVersion);
        if (group.CreatorId != userId)
            throw new DomainException(403, "creator_required", "Only the group creator can delete this group.");
        LedgerEngine.Validate(balances);
        if (balances.Any(b => b.Counterparties.Values.Any(v => v != 0)))
            throw new DomainException(409, "unsettled_group", "Settle every direct debt before deleting this group.");
    }

    public static void EnsureCanLeave(Group group, string userId, bool acknowledgeBalance,
        IReadOnlyList<Balance> balances)
    {
        EnsureWritable(group);
        var member = RequireActiveMember(group, userId);
        if (!acknowledgeBalance && balances.Any(b => b.ParticipantId == member.Id && b.Counterparties.Values.Any(v => v != 0)))
            throw new DomainException(409, "balance_acknowledgement_required", "You still have outstanding debts. Acknowledge them before leaving.");
    }
}
