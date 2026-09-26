using Hisaab.Domain;

namespace Hisaab.Domain.Tests;

internal static class Fixtures
{
    public static readonly DateTimeOffset Now = new(2026, 9, 26, 12, 0, 0, TimeSpan.Zero);

    public static Group Group(params Member[] members) => new("g", "Trip", GroupType.Trip, false, 1, "ua",
        members.Length == 0 ? [new("a", "ua", "A"), new("b", "ub", "B"), new("c", "uc", "C")] : members);

    public static Expense Expense(string payer = "a", long amount = 10_000,
        SplitMode mode = SplitMode.Equal, params SplitParticipant[] participants)
    {
        if (participants.Length == 0) participants = [new("a"), new("b"), new("c")];
        var shares = SplitEngine.Calculate(amount, mode, participants).Shares;
        return new("e", "g", " Dinner ", amount, new DateOnly(2026, 9, 26), payer, mode, participants,
            shares, 1, null, "ua", Now);
    }

    public static Settlement Payment(long amount = 1000) => new("s", "g", "b", "a", amount,
        SettlementMethod.UPI, 1, false, "ub", Now);

    public static void Consistent(IReadOnlyList<Balance> balances)
    {
        LedgerEngine.Validate(balances);
        Assert.Equal(0, balances.Sum(b => b.NetPaise));
        foreach (var balance in balances)
        {
            Assert.Equal(balance.NetPaise, balance.Counterparties.Values.Sum());
            foreach (var pair in balance.Counterparties)
                Assert.Equal(-pair.Value, balances.Single(b => b.ParticipantId == pair.Key).Counterparties[balance.ParticipantId]);
        }
    }

    public static void SameBalances(IReadOnlyList<Balance> expected, IReadOnlyList<Balance> actual)
    {
        Assert.Equal(expected.Select(b => b.ParticipantId), actual.Select(b => b.ParticipantId));
        for (var i = 0; i < expected.Count; i++)
        {
            Assert.Equal(expected[i].NetPaise, actual[i].NetPaise);
            Assert.Equal(expected[i].Counterparties.OrderBy(p => p.Key), actual[i].Counterparties.OrderBy(p => p.Key));
        }
    }
}
