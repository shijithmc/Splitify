using Hisaab.Domain;

namespace Hisaab.Domain.Tests;

public sealed class LedgerEngineTests
{
    [Fact]
    public void ExpenseThenReversalRestoresOriginalRowsWithoutMutatingInput()
    {
        var original = LedgerEngine.Empty(["a", "b", "c"]);
        var expense = Fixtures.Expense();
        var added = LedgerEngine.ApplyExpense(original, expense);
        Assert.Equal(6666, added.Single(b => b.ParticipantId == "a").NetPaise);
        Assert.Equal(-3333, added.Single(b => b.ParticipantId == "b").NetPaise);
        Assert.All(original, b => Assert.Empty(b.Counterparties));
        Fixtures.Consistent(added);
        Fixtures.SameBalances(original, LedgerEngine.ApplyExpense(added, expense, -1));
    }

    [Fact]
    public void CyclesRemainVisibleEvenWhenAllNetBalancesAreZero()
    {
        var balances = LedgerEngine.Empty(["a", "b", "c"]);
        foreach (var (payer, debtor) in new[] { ("a", "b"), ("b", "c"), ("c", "a") })
            balances = LedgerEngine.ApplyExpense(balances, Fixtures.Expense(payer, 100, SplitMode.Exact, new SplitParticipant(debtor, 100)));
        Fixtures.Consistent(balances);
        Assert.All(balances, b => { Assert.Equal(0, b.NetPaise); Assert.Equal(2, b.Counterparties.Count); });
        Assert.Equal("unsettled_group", Assert.Throws<DomainException>(() => GroupRules.EnsureCanDelete(Fixtures.Group(), "ua", 1, balances)).Code);
        Assert.Equal("balance_acknowledgement_required", Assert.Throws<DomainException>(() => GroupRules.EnsureCanLeave(Fixtures.Group(), "ub", false, balances)).Code);
    }

    [Fact]
    public void PartialSettlementAndDisputeAreExactInverses()
    {
        var original = LedgerEngine.ApplyExpense(LedgerEngine.Empty(["a", "b", "c"]), Fixtures.Expense());
        var payment = SettlementRules.Create(Fixtures.Group(), Fixtures.Payment(), original, "ub", Fixtures.Now);
        var settled = LedgerEngine.ApplySettlement(original, payment);
        Assert.Equal(-2333, settled.Single(b => b.ParticipantId == "b").NetPaise);
        Assert.Equal(5666, settled.Single(b => b.ParticipantId == "a").NetPaise);
        var disputed = SettlementRules.Dispute(Fixtures.Group(), payment, "ua", 1);
        Assert.True(disputed.Disputed);
        Assert.Equal(2, disputed.Version);
        Fixtures.SameBalances(original, LedgerEngine.ApplySettlement(settled, disputed, -1));
        Assert.Equal("settlement_disputed", Assert.Throws<DomainException>(() => SettlementRules.Dispute(Fixtures.Group(), disputed, "ua", 2)).Code);
        Assert.Equal("version_conflict", Assert.Throws<DomainException>(() => SettlementRules.Dispute(Fixtures.Group(), disputed, "ua", 1)).Code);
    }

    [Fact]
    public void ForgedSharesAndUnknownPayersAreRejected()
    {
        var balances = LedgerEngine.Empty(["a", "b", "c"]);
        Assert.Equal("invalid_expense_shares", Assert.Throws<DomainException>(() => LedgerEngine.ApplyExpense(balances,
            Fixtures.Expense() with { Shares = new Dictionary<string, long> { ["a"] = 10000 } })).Code);
        Assert.Throws<DomainException>(() => LedgerEngine.ApplyExpense(balances, Fixtures.Expense() with { PayerId = "outsider" }));
    }

    [Fact]
    public void DetectsBrokenAntisymmetryNetAndUnknownCounterparty()
    {
        Assert.Throws<DomainException>(() => LedgerEngine.Validate([
            new("a", 1, new Dictionary<string, long> { ["b"] = 1 }), new("b", 0, new Dictionary<string, long>())]));
        Assert.Throws<DomainException>(() => LedgerEngine.Validate([new("a", 1, new Dictionary<string, long>())]));
        Assert.Throws<DomainException>(() => LedgerEngine.Validate([new("a", 1, new Dictionary<string, long> { ["outside"] = 1 })]));
    }

    [Fact]
    public void RejectsOverflowWithoutMutatingLedger()
    {
        IReadOnlyList<Balance> balances = [new("a", long.MaxValue, new Dictionary<string, long> { ["b"] = long.MaxValue }),
            new("b", -long.MaxValue, new Dictionary<string, long> { ["a"] = -long.MaxValue })];
        Assert.Equal("ledger_overflow", Assert.Throws<DomainException>(() => LedgerEngine.ApplyExpense(balances,
            Fixtures.Expense("a", 1, SplitMode.Exact, new SplitParticipant("b", 1)))).Code);
        Assert.Equal(long.MaxValue, balances[0].NetPaise);
    }

    [Fact]
    public void RandomSequenceOfAddsEditsDeletesAndRestoresConservesLedger()
    {
        var random = new Random(56234);
        var ids = Enumerable.Range(0, 50).Select(i => $"p{i:00}").ToArray();
        var zero = LedgerEngine.Empty(ids);
        var balances = zero;
        var expenses = new List<Expense>();
        for (var i = 0; i < 300; i++)
        {
            var participants = ids.Where(_ => random.Next(2) == 0).Select(id => new SplitParticipant(id, random.Next(1, 10001))).ToArray();
            if (participants.Length == 0) participants = [new(ids[0], 1)];
            var expense = Fixtures.Expense(ids[random.Next(ids.Length)], random.NextInt64(1, Money.MaximumExpensePaise + 1), SplitMode.Shares, participants);
            balances = LedgerEngine.ApplyExpense(balances, expense);
            if (i % 3 == 0)
            {
                balances = LedgerEngine.ApplyExpense(balances, expense, -1);
                expense = Fixtures.Expense(ids[random.Next(ids.Length)], random.NextInt64(1, Money.MaximumExpensePaise + 1), SplitMode.Shares, participants);
                balances = LedgerEngine.ApplyExpense(balances, expense);
            }
            if (i % 5 == 0)
            {
                var beforeDelete = balances;
                balances = LedgerEngine.ApplyExpense(balances, expense, -1);
                balances = LedgerEngine.ApplyExpense(balances, expense);
                Fixtures.SameBalances(beforeDelete, balances);
            }
            expenses.Add(expense);
            Fixtures.Consistent(balances);
        }
        foreach (var expense in expenses.AsEnumerable().Reverse()) balances = LedgerEngine.ApplyExpense(balances, expense, -1);
        Fixtures.SameBalances(zero, balances);
    }
}
