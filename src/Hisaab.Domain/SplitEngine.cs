using System.Collections.ObjectModel;
using System.Globalization;

namespace Hisaab.Domain;

public static class SplitEngine
{
    public static SplitResult Calculate(long amountPaise, SplitMode mode,
        IReadOnlyList<SplitParticipant> participants)
    {
        Money.RequireExpenseAmount(amountPaise);
        if (participants is null || participants.Count is < 1 or > GroupRules.MaximumMembers)
            throw new DomainException(422, "invalid_participants", "Select between 1 and 50 participants.");
        if (participants.Any(p => p is null || string.IsNullOrWhiteSpace(p.ParticipantId)) ||
            participants.Select(p => p.ParticipantId).Distinct(StringComparer.Ordinal).Count() != participants.Count)
            throw new DomainException(422, "invalid_participants", "Participants must have unique, non-empty IDs.");
        if (!Enum.IsDefined(mode))
            throw new DomainException(422, "invalid_split_mode", "Choose a supported split mode.");

        var sorted = participants.OrderBy(p => p.ParticipantId, StringComparer.Ordinal).ToArray();
        var shares = new Dictionary<string, long>(StringComparer.Ordinal);
        long denominator;
        switch (mode)
        {
            case SplitMode.Exact:
                if (sorted.Any(p => p.Value < 0 || p.Value > Money.MaximumExpensePaise))
                    throw new DomainException(422, "invalid_exact_amount", "Exact amounts must be non-negative integer paise within the expense limit.");
                var exactSum = sorted.Sum(p => p.Value);
                if (exactSum != amountPaise)
                    throw new DomainException(422, "split_total_mismatch", exactSum < amountPaise
                        ? $"{Money.Format(amountPaise - exactSum)} left to assign"
                        : $"{Money.Format(exactSum - amountPaise)} over-assigned");
                foreach (var p in sorted) shares.Add(p.ParticipantId, p.Value);
                return new SplitResult(new ReadOnlyDictionary<string, long>(shares), Array.Empty<string>());
            case SplitMode.Percentage:
                if (sorted.Any(p => p.Value is < 0 or > 10_000))
                    throw new DomainException(422, "invalid_percentage", "Percentages must be integer basis points between 0 and 10,000.");
                denominator = sorted.Sum(p => p.Value);
                if (denominator != 10_000)
                {
                    var difference = (Math.Abs(10_000 - denominator) / 100m).ToString("0.##", CultureInfo.InvariantCulture);
                    throw new DomainException(422, "split_total_mismatch", denominator < 10_000
                        ? $"{difference}% left to assign" : $"{difference}% over-assigned");
                }
                break;
            case SplitMode.Shares:
                if (sorted.Any(p => p.Value is < 1 or > 10_000))
                    throw new DomainException(422, "invalid_share_weight", "Share weights must be integers between 1 and 10,000.");
                denominator = sorted.Sum(p => p.Value);
                break;
            default:
                denominator = sorted.Length;
                break;
        }

        foreach (var p in sorted)
        {
            var weight = mode == SplitMode.Equal ? 1 : p.Value;
            shares.Add(p.ParticipantId, checked(amountPaise * weight) / denominator);
        }
        var order = sorted.Where(p => mode != SplitMode.Percentage || p.Value > 0)
            .Select(p => p.ParticipantId).ToArray();
        var remainder = amountPaise - shares.Values.Sum();
        for (var index = 0; index < remainder; index++) shares[order[index]]++;
        return new SplitResult(new ReadOnlyDictionary<string, long>(shares), Array.AsReadOnly(order));
    }
}
