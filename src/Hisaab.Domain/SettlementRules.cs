namespace Hisaab.Domain;

public static class SettlementRules
{
    public static Settlement Create(Group group, Settlement draft, IReadOnlyList<Balance> balances,
        string actorId, DateTimeOffset now)
    {
        GroupRules.EnsureWritable(group);
        if (!group.Members.Any(m => m.UserId == actorId && !m.IsDeleted))
            throw new DomainException(404, "group_not_found", "Group not found.");
        if (string.IsNullOrWhiteSpace(draft.Id) || draft.GroupId != group.Id || draft.FromId == draft.ToId ||
            !Enum.IsDefined(draft.Method))
            throw new DomainException(422, "invalid_settlement", "Provide a valid settlement between two different participants.");
        var from = group.Members.SingleOrDefault(m => m.Id == draft.FromId);
        var to = group.Members.SingleOrDefault(m => m.Id == draft.ToId);
        if (from is null || to is null)
            throw new DomainException(422, "invalid_settlement_member", "Both participants must belong to this group.");
        var onBehalf = group.CreatorId == actorId && group.Members.Any(m => m.UserId == actorId && !m.HasLeft) &&
            (from.IsPlaceholder || from.IsExternal || from.IsDeleted || to.IsPlaceholder || to.IsExternal || to.IsDeleted);
        if (from.UserId != actorId && to.UserId != actorId && !onBehalf)
            throw new DomainException(403, "settlement_participant_required", "Only an involved participant or an authorized organizer can record this payment.");
        Money.RequireExpenseAmount(draft.AmountPaise);
        LedgerEngine.Validate(balances);
        var outstanding = balances.SingleOrDefault(b => b.ParticipantId == draft.ToId)?.Counterparties.GetValueOrDefault(draft.FromId) ?? 0;
        if (outstanding <= 0 || draft.AmountPaise > outstanding)
            throw new DomainException(422, "settlement_exceeds_debt", "Payment cannot exceed the outstanding direct debt.");
        return draft with { Version = 1, Disputed = false, CreatedBy = actorId, CreatedAt = now.ToUniversalTime() };
    }

    public static Settlement Dispute(Group group, Settlement current, string actorId, long expectedVersion)
    {
        GroupRules.EnsureWritable(group);
        if (current.GroupId != group.Id)
            throw new DomainException(404, "settlement_not_found", "Settlement not found.");
        var receiver = group.Members.SingleOrDefault(m => m.Id == current.ToId);
        if (receiver?.UserId != actorId || receiver.IsDeleted)
            throw new DomainException(403, "receiver_required", "Only the receiver can dispute this payment.");
        GroupRules.RequireVersion(current.Version, expectedVersion);
        if (current.Disputed)
            throw new DomainException(409, "settlement_disputed", "This payment has already been disputed.");
        return current with { Version = checked(current.Version + 1), Disputed = true };
    }
}
