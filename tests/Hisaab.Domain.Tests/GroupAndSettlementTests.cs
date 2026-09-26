using Hisaab.Domain;

namespace Hisaab.Domain.Tests;

public sealed class GroupAndSettlementTests
{
    [Fact]
    public void FiftyMemberLimitIncludesPlaceholdersAndFormerMembers()
    {
        var members = Enumerable.Range(0, 50).Select(i => new Member($"p{i}", null, "Placeholder", IsPlaceholder: true, HasLeft: i % 2 == 0)).ToArray();
        var group = Fixtures.Group(members);
        GroupRules.ValidateRoster(group);
        Assert.Equal("member_limit", Assert.Throws<DomainException>(() => GroupRules.EnsureCanAddMember(group)).Code);
        Assert.Throws<DomainException>(() => GroupRules.ValidateRoster(group with { Members = members.Append(new Member("extra", null, "X")).ToArray() }));
    }

    [Fact]
    public void DirectFriendshipsRetainAtMostTwoIdentities()
    {
        var group = Fixtures.Group(new("a", "ua", "A"), new("b", "ub", "B")) with { Type = GroupType.Direct };
        Assert.Throws<DomainException>(() => GroupRules.EnsureCanAddMember(group));
        Assert.Throws<DomainException>(() => GroupRules.ValidateRoster(Fixtures.Group() with { Type = GroupType.Direct }));
    }

    [Fact]
    public void SameAccountCannotClaimTwoLedgerIdentities()
    {
        Assert.Equal("duplicate_member", Assert.Throws<DomainException>(() => GroupRules.ValidateRoster(Fixtures.Group(
            new("a", "ua", "A"), new("b", "ua", "B")))).Code);
    }

    [Fact]
    public void SettlementRejectsOverpaymentAndUnrelatedActor()
    {
        var balances = LedgerEngine.ApplyExpense(LedgerEngine.Empty(["a", "b", "c"]), Fixtures.Expense());
        Assert.Equal("settlement_exceeds_debt", Assert.Throws<DomainException>(() => SettlementRules.Create(Fixtures.Group(), Fixtures.Payment(3334), balances, "ub", Fixtures.Now)).Code);
        Assert.Equal("settlement_participant_required", Assert.Throws<DomainException>(() => SettlementRules.Create(Fixtures.Group(), Fixtures.Payment(), balances, "uc", Fixtures.Now)).Code);
        Assert.Equal("receiver_required", Assert.Throws<DomainException>(() => SettlementRules.Dispute(Fixtures.Group(), Fixtures.Payment(), "ub", 1)).Code);
    }

    [Fact]
    public void CreatorCanRecordForPlaceholderAndClaimedReceiverCanDispute()
    {
        var group = Fixtures.Group(new("a", "ua", "A"), new("b", null, "B", IsPlaceholder: true), new("c", "uc", "C"));
        var balances = LedgerEngine.ApplyExpense(LedgerEngine.Empty(["a", "b", "c"]), Fixtures.Expense("b"));
        var payment = SettlementRules.Create(group, Fixtures.Payment() with { FromId = "c", ToId = "b" }, balances, "ua", Fixtures.Now);
        Assert.Equal("ua", payment.CreatedBy);
        var claimed = group with { Members = group.Members.Select(m => m.Id == "b" ? m with { UserId = "ub", IsPlaceholder = false } : m).ToArray() };
        Assert.True(SettlementRules.Dispute(claimed, payment, "ub", 1).Disputed);
    }

    [Fact]
    public void ExplicitAcknowledgementAllowsLeavingUnresolvedDebt()
    {
        var balances = LedgerEngine.ApplyExpense(LedgerEngine.Empty(["a", "b", "c"]), Fixtures.Expense());
        Assert.Throws<DomainException>(() => GroupRules.EnsureCanLeave(Fixtures.Group(), "ub", false, balances));
        GroupRules.EnsureCanLeave(Fixtures.Group(), "ub", true, balances);
        GroupRules.EnsureCanDelete(Fixtures.Group(), "ua", 1, LedgerEngine.Empty(["a", "b", "c"]));
        Assert.Throws<DomainException>(() => GroupRules.EnsureCanDelete(Fixtures.Group(), "ub", 1, LedgerEngine.Empty(["a", "b", "c"])));
    }
    [Fact]
    public void FormerParticipantCanSettleRetainedDebt()
    {
        var group = Fixtures.Group() with
        {
            Members = Fixtures.Group().Members.Select(m => m.Id == "b" ? m with { HasLeft = true } : m).ToArray()
        };
        var balances = LedgerEngine.ApplyExpense(LedgerEngine.Empty(["a", "b", "c"]), Fixtures.Expense());
        Assert.Equal("ub", SettlementRules.Create(group, Fixtures.Payment(), balances, "ub", Fixtures.Now).CreatedBy);
    }

}
