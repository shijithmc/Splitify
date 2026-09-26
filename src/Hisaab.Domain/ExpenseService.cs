namespace Hisaab.Domain;

public static class ExpenseService
{
    public static Expense Create(Group group, Expense draft, string actorId, DateTimeOffset now)
    {
        GroupRules.EnsureWritable(group);
        GroupRules.ValidateRoster(group);
        GroupRules.RequireActiveMember(group, actorId);
        if (group.ExpenseCount >= GroupRules.MaximumExpenses)
            throw new DomainException(422, "expense_limit", "This group has reached the limit of 10,000 allocated expenses.");
        var normalized = Normalize(group, draft);
        return normalized with { Version = 1, DeletedAt = null, CreatedBy = actorId, UpdatedAt = now.ToUniversalTime() };
    }

    public static Expense Update(Group group, Expense current, Expense draft, string actorId,
        long expectedVersion, DateTimeOffset now)
    {
        RequireChange(group, current, actorId, expectedVersion);
        if (current.DeletedAt is not null)
            throw new DomainException(409, "expense_deleted", "Restore this expense before editing it.");
        if (current.Id != draft.Id || current.GroupId != draft.GroupId)
            throw new DomainException(422, "expense_identity_mismatch", "Expense identity cannot change.");
        var normalized = Normalize(group, draft);
        return normalized with
        {
            Version = checked(current.Version + 1),
            DeletedAt = null,
            CreatedBy = current.CreatedBy,
            UpdatedAt = now.ToUniversalTime()
        };
    }

    public static Expense Delete(Group group, Expense current, string actorId, long expectedVersion,
        DateTimeOffset now)
    {
        RequireChange(group, current, actorId, expectedVersion);
        if (current.DeletedAt is not null)
            throw new DomainException(409, "expense_deleted", "This expense has already been deleted.");
        return current with { Version = checked(current.Version + 1), DeletedAt = now.ToUniversalTime(), UpdatedAt = now.ToUniversalTime() };
    }

    public static Expense Restore(Group group, Expense current, string actorId, long expectedVersion,
        DateTimeOffset now)
    {
        RequireChange(group, current, actorId, expectedVersion);
        if (current.DeletedAt is null)
            throw new DomainException(409, "expense_not_deleted", "This expense is not deleted.");
        if (now < current.DeletedAt || now > current.DeletedAt.Value.AddDays(30))
            throw new DomainException(409, "restore_window_expired", "Expenses can only be restored within 30 days of deletion.");
        return current with { Version = checked(current.Version + 1), DeletedAt = null, UpdatedAt = now.ToUniversalTime() };
    }

    private static Expense Normalize(Group group, Expense draft)
    {
        if (string.IsNullOrWhiteSpace(draft.Id) || draft.GroupId != group.Id)
            throw new DomainException(422, "invalid_expense_identity", "Provide an expense ID for this group.");
        var description = draft.Description?.Trim() ?? "";
        if (description.EnumerateRunes().Count() is < 1 or > 100)
            throw new DomainException(422, "invalid_description", "Description must contain between 1 and 100 Unicode characters.");
        var split = SplitEngine.Calculate(draft.AmountPaise, draft.Mode, draft.Participants);
        var eligible = group.Members.Where(m => !m.HasLeft && !m.IsDeleted).Select(m => m.Id).ToHashSet(StringComparer.Ordinal);
        if (!eligible.Contains(draft.PayerId) || draft.Participants.Any(p => !eligible.Contains(p.ParticipantId)))
            throw new DomainException(422, "invalid_expense_member", "The payer and every participant must be current group members.");
        return draft with
        {
            Description = description,
            Shares = split.Shares,
            Participants = Array.AsReadOnly(draft.Participants.OrderBy(p => p.ParticipantId, StringComparer.Ordinal).ToArray())
        };
    }

    private static void RequireChange(Group group, Expense current, string actorId, long expectedVersion)
    {
        GroupRules.EnsureWritable(group);
        if (current.GroupId != group.Id)
            throw new DomainException(404, "expense_not_found", "Expense not found.");
        var actor = GroupRules.RequireActiveMember(group, actorId);
        if (current.PayerId != actor.Id && !current.Participants.Any(p => p.ParticipantId == actor.Id))
            throw new DomainException(403, "expense_participant_required", "Only an original expense participant can change this expense.");
        if (current.Version != expectedVersion)
            throw new DomainException(409, "version_conflict", "This expense changed — review latest");
    }
}
