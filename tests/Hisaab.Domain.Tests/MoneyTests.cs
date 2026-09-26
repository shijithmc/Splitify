using Hisaab.Domain;

namespace Hisaab.Domain.Tests;

public sealed class MoneyTests
{
    [Theory]
    [InlineData("0.01", 1)]
    [InlineData("0.1", 10)]
    [InlineData("100", 10000)]
    [InlineData(" 100.10 ", 10010)]
    [InlineData("10000000.00", 1000000000)]
    public void ParsesDecimalWithoutFloatingPoint(string input, long expected) => Assert.Equal(expected, Money.ParsePaise(input));

    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("1.001")]
    [InlineData("1e2")]
    [InlineData("1,000")]
    [InlineData("NaN")]
    [InlineData(".1")]
    [InlineData("1.")]
    [InlineData("10000000.01")]
    [InlineData("999999999999999999999999999999999999")]
    [InlineData("١")]
    [InlineData("")]
    [InlineData("1.1.1")]
    public void RejectsMalformedOrOutOfRangeAmounts(string input) => Assert.Throws<DomainException>(() => Money.ParsePaise(input));
}
