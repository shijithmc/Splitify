using System.Collections.ObjectModel;

namespace Hisaab.Domain;

public static class LedgerEngine
{
    public static IReadOnlyList<Balance> Empty(IEnumerable<string> participantIds)
    {
        var ids = participantIds.ToArray();
        if (ids.Length is < 1 or > GroupRules.MaximumMembers || ids.Any(string.IsNullOrWhiteSpace) ||
            ids.Distinct(StringComparer.Ordinal).Count() != ids.Length)
            throw new DomainException(422, "invalid_roster", "Provide between 1 and 50 unique ledger identities.");
        return Array.AsReadOnly(ids.Order(StringComparer.Ordinal).Select(id => new Balance(id, 0,
            new ReadOnlyDictionary<string, long>(new Dictionary<string, long>(StringComparer.Ordinal)))).ToArray());
    }

    public static IReadOnlyList<Balance> ApplyExpense(IReadOnlyList<Balance> balances, Expense expense,
        int direction = 1)
    {
        RequireDirection(direction);
        var computed = SplitEngine.Calculate(expense.AmountPaise, expense.Mode, expense.Participants);
        if (expense.Shares.Count != computed.Shares.Count || computed.Shares.Any(p => !expense.Shares.TryGetValue(p.Key, out var actual) || actual != p.Value))
            throw new DomainException(422, "invalid_expense_shares", "Expense shares do not match the split calculation.");
        var maps = Copy(balances);
        RequireParticipant(maps, expense.PayerId);
        foreach (var share in expense.Shares)
        {
            RequireParticipant(maps, share.Key);
            if (share.Key != expense.PayerId) AddPair(maps, expense.PayerId, share.Key, checked(share.Value * direction));
        }
        return Freeze(maps);
    }

    public static IReadOnlyList<Balance> ApplySettlement(IReadOnlyList<Balance> balances,
        Settlement settlement, int direction = 1)
    {
        RequireDirection(direction);
        Money.RequireExpenseAmount(settlement.AmountPaise);
        if (settlement.FromId == settlement.ToId)
            throw new DomainException(422, "invalid_settlement", "A settlement requires two different participants.");
        var maps = Copy(balances);
        RequireParticipant(maps, settlement.FromId);
        RequireParticipant(maps, settlement.ToId);
        AddPair(maps, settlement.FromId, settlement.ToId, checked(settlement.AmountPaise * direction));
        return Freeze(maps);
    }

    public static void Validate(IReadOnlyList<Balance> balances)
    {
        if (balances is null || balances.Count is < 1 or > GroupRules.MaximumMembers ||
            balances.Any(b => b is null || string.IsNullOrWhiteSpace(b.ParticipantId) || b.Counterparties is null) ||
            balances.Select(b => b.ParticipantId).Distinct(StringComparer.Ordinal).Count() != balances.Count)
            throw InvalidLedger();
        var rows = balances.ToDictionary(b => b.ParticipantId, StringComparer.Ordinal);
        try
        {
            long total = 0;
            foreach (var balance in balances)
            {
                long net = 0;
                foreach (var pair in balance.Counterparties)
                {
                    if (pair.Key == balance.ParticipantId || !rows.TryGetValue(pair.Key, out var other) ||
                        other.Counterparties.GetValueOrDefault(balance.ParticipantId) != checked(-pair.Value))
                        throw InvalidLedger();
                    net = checked(net + pair.Value);
                }
                if (net != balance.NetPaise) throw InvalidLedger();
                total = checked(total + net);
            }
            if (total != 0) throw InvalidLedger();
        }
        catch (OverflowException) { throw InvalidLedger(); }
    }

    private static Dictionary<string, Dictionary<string, long>> Copy(IReadOnlyList<Balance> balances)
    {
        Validate(balances);
        return balances.ToDictionary(b => b.ParticipantId,
            b => b.Counterparties.ToDictionary(p => p.Key, p => p.Value, StringComparer.Ordinal), StringComparer.Ordinal);
    }

    private static void AddPair(Dictionary<string, Dictionary<string, long>> maps, string creditor,
        string debtor, long delta)
    {
        try
        {
            var next = checked(maps[creditor].GetValueOrDefault(debtor) + delta);
            var opposite = checked(-next);
            if (next == 0)
            {
                maps[creditor].Remove(debtor);
                maps[debtor].Remove(creditor);
            }
            else
            {
                maps[creditor][debtor] = next;
                maps[debtor][creditor] = opposite;
            }
        }
        catch (OverflowException)
        {
            throw new DomainException(422, "ledger_overflow", "The resulting balance exceeds the supported limit.");
        }
    }

    private static IReadOnlyList<Balance> Freeze(Dictionary<string, Dictionary<string, long>> maps)
    {
        try
        {
            var result = maps.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => new Balance(p.Key,
                p.Value.Values.Aggregate(0L, (total, value) => checked(total + value)),
                new ReadOnlyDictionary<string, long>(p.Value))).ToArray();
            Validate(result);
            return Array.AsReadOnly(result);
        }
        catch (OverflowException)
        {
            throw new DomainException(422, "ledger_overflow", "The resulting balance exceeds the supported limit.");
        }
    }

    private static void RequireParticipant(Dictionary<string, Dictionary<string, long>> maps, string id)
    {
        if (!maps.ContainsKey(id))
            throw new DomainException(422, "invalid_ledger_participant", "Every participant must have a group balance row.");
    }

    private static void RequireDirection(int direction)
    {
        if (direction is not (1 or -1)) throw new ArgumentOutOfRangeException(nameof(direction));
    }

    private static DomainException InvalidLedger() => new(409, "invalid_ledger", "Group balances failed consistency validation.");
}
