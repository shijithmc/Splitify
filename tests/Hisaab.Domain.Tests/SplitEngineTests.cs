using Hisaab.Domain;

namespace Hisaab.Domain.Tests;

public sealed class SplitEngineTests
{
    [Fact]
    public void EqualGoldenVectorUsesOrdinalOrder()
    {
        var result = SplitEngine.Calculate(10_000, SplitMode.Equal, [new("c"), new("a"), new("b")]);
        Assert.Equal(3334, result.Shares["a"]);
        Assert.Equal(3333, result.Shares["b"]);
        Assert.Equal(3333, result.Shares["c"]);
        Assert.Equal(["a", "b", "c"], result.RoundingOrder);
    }

    [Fact]
    public void ZeroPercentageNeverReceivesRemainder()
    {
        var result = SplitEngine.Calculate(1, SplitMode.Percentage, [new("a", 0), new("b", 5000), new("c", 5000)]);
        Assert.Equal(0, result.Shares["a"]);
        Assert.Equal(1, result.Shares["b"]);
        Assert.Equal(0, result.Shares["c"]);
        Assert.Equal(["b", "c"], result.RoundingOrder);
    }

    [Fact]
    public void SharesGoldenVectorUsesWeightAndOrdinalRemainder()
    {
        var result = SplitEngine.Calculate(1001, SplitMode.Shares, [new("c", 3), new("a", 1), new("b", 2)]);
        Assert.Equal(167, result.Shares["a"]);
        Assert.Equal(334, result.Shares["b"]);
        Assert.Equal(500, result.Shares["c"]);
    }

    [Theory]
    [InlineData(SplitMode.Exact, 8750, "₹12.50 left to assign")]
    [InlineData(SplitMode.Exact, 11250, "₹12.50 over-assigned")]
    [InlineData(SplitMode.Percentage, 9000, "10% left to assign")]
    public void IncompleteSplitsReportPreciseDifference(SplitMode mode, long value, string message)
    {
        Assert.Equal(message, Assert.Throws<DomainException>(() => SplitEngine.Calculate(10_000, mode, [new("a", value)])).Message);
    }

    [Fact]
    public void PercentageExcessReportsPreciseDifference()
    {
        Assert.Equal("10% over-assigned", Assert.Throws<DomainException>(() => SplitEngine.Calculate(10_000,
            SplitMode.Percentage, [new("a", 6000), new("b", 5000)])).Message);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(1_000_000_001)]
    [InlineData(long.MaxValue)]
    public void RejectsOutOfRangeTotals(long amount) => Assert.Throws<DomainException>(() =>
        SplitEngine.Calculate(amount, SplitMode.Equal, [new("a")]));

    [Fact]
    public void ExactSplitAcceptsZeroAndConservesAmount()
    {
        var result = SplitEngine.Calculate(1, SplitMode.Exact, [new("a", 0), new("b", 1)]);
        Assert.Equal(0, result.Shares["a"]);
        Assert.Equal(1, result.Shares["b"]);
        Assert.Empty(result.RoundingOrder);
    }

    [Fact]
    public void RejectsDuplicatesMissingAndMoreThanFiftyParticipants()
    {
        Assert.Throws<DomainException>(() => SplitEngine.Calculate(1, SplitMode.Equal, [new("a"), new("a")]));
        Assert.Throws<DomainException>(() => SplitEngine.Calculate(1, SplitMode.Equal, [new("")]));
        Assert.Throws<DomainException>(() => SplitEngine.Calculate(1, SplitMode.Equal, []));
        Assert.Throws<DomainException>(() => SplitEngine.Calculate(1, SplitMode.Equal,
            Enumerable.Range(0, 51).Select(i => new SplitParticipant($"p{i}")).ToArray()));
    }

    [Theory]
    [InlineData(SplitMode.Exact, -1)]
    [InlineData(SplitMode.Exact, long.MaxValue)]
    [InlineData(SplitMode.Percentage, -1)]
    [InlineData(SplitMode.Percentage, 10001)]
    [InlineData(SplitMode.Shares, 0)]
    [InlineData(SplitMode.Shares, 10001)]
    public void RejectsInvalidValues(SplitMode mode, long value) => Assert.Throws<DomainException>(() =>
        SplitEngine.Calculate(1, mode, [new("a", value)]));

    [Fact]
    public void RandomSplitsConservePaiseAndArePermutationInvariant()
    {
        var random = new Random(72904);
        for (var trial = 0; trial < 1000; trial++)
        {
            var size = random.Next(1, 51);
            long amount = trial % 2 == 0 ? random.NextInt64(1, Money.MaximumExpensePaise + 1) : 1;
            var ids = Enumerable.Range(0, size).Select(i => $"p{i:00}").ToArray();
            foreach (var mode in new[] { SplitMode.Equal, SplitMode.Exact, SplitMode.Percentage, SplitMode.Shares })
            {
                var values = new long[size];
                if (mode == SplitMode.Exact || mode == SplitMode.Percentage)
                {
                    var remaining = mode == SplitMode.Exact ? amount : 10000;
                    for (var i = 0; i < size - 1; i++)
                    {
                        values[i] = random.NextInt64(remaining + 1);
                        remaining -= values[i];
                    }
                    values[^1] = remaining;
                }
                else if (mode == SplitMode.Shares)
                    for (var i = 0; i < size; i++) values[i] = random.Next(1, 10001);
                var participants = ids.Select((id, i) => new SplitParticipant(id, values[i])).ToArray();
                var split = SplitEngine.Calculate(amount, mode, participants);
                Assert.Equal(amount, split.Shares.Values.Sum());
                Assert.All(split.Shares.Values, share => Assert.InRange(share, 0, amount));
                var reversed = SplitEngine.Calculate(amount, mode, participants.Reverse().ToArray());
                Assert.Equal(split.Shares, reversed.Shares);
                Assert.Equal(split.RoundingOrder, reversed.RoundingOrder);
                if (mode == SplitMode.Percentage)
                    foreach (var zero in participants.Where(p => p.Value == 0)) Assert.Equal(0, split.Shares[zero.ParticipantId]);
            }
        }
    }

    [Fact]
    public void MaximumAmountWithFiftyParticipantsDoesNotOverflow()
    {
        var result = SplitEngine.Calculate(Money.MaximumExpensePaise, SplitMode.Shares,
            Enumerable.Range(0, 50).Select(i => new SplitParticipant($"p{i:00}", 10000)).ToArray());
        Assert.Equal(Money.MaximumExpensePaise, result.Shares.Values.Sum());
        Assert.All(result.Shares.Values, value => Assert.Equal(20_000_000, value));
    }
}
