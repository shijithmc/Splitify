using System.Text.Encodings.Web;
using System.Text.Json;
using Hisaab.Domain.Receipts;

namespace Hisaab.Domain.Tests;

public sealed class ReceiptSplitEngineTests
{
    [Fact]
    public void VersionedSharedVectorsMatchAuthoritativeAllocation()
    {
        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "receipt-splits.v1.json")));
        Assert.Equal(1, document.RootElement.GetProperty("version").GetInt32());
        foreach (var vector in document.RootElement.GetProperty("cases").EnumerateArray())
        {
            var review = vector.GetProperty("review").Deserialize<ReceiptReview>(new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
            var ids = vector.GetProperty("activeMemberIds").EnumerateArray().Select(v => v.GetString()!).ToArray();
            var preview = ReceiptSplitEngine.Calculate(review, ids);
            Assert.Equal(vector.GetProperty("expectedDifferencePaise").GetInt64(), preview.DifferencePaise);
            Assert.Equal(vector.GetProperty("expectedShares").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetInt64()), preview.Shares);
        }
    }

    private static ReceiptReview Review(long total, ReceiptItem[] items, ReceiptCharge[]? charges = null) =>
        new("भोजन / உணவு", new DateOnly(2026, 9, 26), "INR", total, items, charges ?? [], true);
    private static ReceiptItem Item(string id, long total, params string[] ids) => new(id, "Meal", "1", total, total, ids);
    private static ReceiptPreview Calculate(ReceiptReview review) => ReceiptSplitEngine.Calculate(review, ["a", "b", "c"]);
    private static ReceiptReview Confirm(ReceiptReview review) => review with { DifferenceAcknowledged = true, AcknowledgedReviewHash = ReceiptSplitEngine.Hash(review) };

    [Fact]
    public void EqualItemRoundingUsesSortedStableParticipantIds()
    {
        var preview = Calculate(Review(10000, [Item("meal", 10000, "c", "a", "b")]));
        Assert.Equal(3334, preview.Shares["a"]);
        Assert.Equal(3333, preview.Shares["b"]);
        Assert.Equal(3333, preview.Shares["c"]);
        Assert.Equal(preview.Shares, Calculate(Review(10000, [Item("meal", 10000, "b", "c", "a")])).Shares);
    }

    [Fact]
    public void MultipleTinyDiscountsCannotMakeSmallSharesNegative()
    {
        var preview = Calculate(Review(99, [Item("one", 1, "a"), Item("two", 100, "b")],
            [new("d1", "Discount", "Discount", -1), new("d2", "Discount", "Discount", -1)]));
        Assert.Equal(0, preview.Shares["a"]);
        Assert.Equal(99, preview.Shares["b"]);
        Assert.Equal(-1, preview.People.Sum(p => p.Charges.Single(c => c.Id == "d1").AmountPaise));
        Assert.Equal(-1, preview.People.Sum(p => p.Charges.Single(c => c.Id == "d2").AmountPaise));
    }

    [Fact]
    public void InclusiveTaxIsInformationalAndOverridesUseTheirOwnWeights()
    {
        var preview = Calculate(Review(360, [Item("one", 100, "a"), Item("two", 200, "b")],
            [new("included", "VAT included", "Tax", 50, true), new("gst", "GST", "Tax", 30),
                new("service", "Service", "Service", 30, Weights: new Dictionary<string, long> { ["a"] = 1, ["b"] = 0 })]));
        Assert.Equal(140, preview.Shares["a"]);
        Assert.Equal(220, preview.Shares["b"]);
        Assert.All(preview.People, p => Assert.Equal(p.TotalPaise, p.ItemsPaise + p.Charges.Where(c => !c.IncludedInItemPrices).Sum(c => c.AmountPaise)));
        Assert.Equal(50, preview.People.Sum(p => p.Charges.Single(c => c.Id == "included").AmountPaise));
    }

    [Fact]
    public void PositiveChargesAreAppliedBeforeNegativeOverrides()
    {
        var preview = Calculate(Review(101, [Item("one", 1, "a"), Item("two", 100, "b")],
            [new("discount", "Discount", "Discount", -10, Weights: new Dictionary<string, long> { ["a"] = 1 }),
                new("tip", "Tip", "Tip", 10, Weights: new Dictionary<string, long> { ["a"] = 1 })]));
        Assert.Equal(1, preview.Shares["a"]);
        Assert.Equal(100, preview.Shares["b"]);
    }

    [Theory]
    [InlineData(100, false)]
    [InlineData(101, true)]
    [InlineData(-100, false)]
    [InlineData(-101, true)]
    public void DifferenceThresholdIsExactAndAlwaysProducesAnAdjustment(long difference, bool requiresAcknowledgement)
    {
        var review = Review(1000 + difference, [Item("one", 1000, "a", "b")]);
        var preview = ReceiptSplitEngine.Calculate(review, ["a", "b"], false);
        Assert.Equal(difference, preview.DifferencePaise);
        Assert.Equal(requiresAcknowledgement, preview.RequiresDifferenceAcknowledgement);
        if (requiresAcknowledgement) Assert.Equal("receipt_reconciliation_required", Assert.Throws<DomainException>(() => Calculate(review)).Code);
        var saved = Calculate(Confirm(review));
        Assert.Equal(1000 + difference, saved.Shares.Values.Sum());
        Assert.Equal(difference, saved.People.Sum(p => p.Charges.Single(c => c.Id == "__difference").AmountPaise));
    }

    [Fact]
    public void EditingReviewInvalidatesDifferenceAcknowledgement()
    {
        var review = Confirm(Review(386000, [Item("subtotal", 327200, "a", "b")],
            [new("cgst", "CGST", "Tax", 8200), new("sgst", "SGST", "Tax", 8200),
                new("service", "Service", "Service", 32700), new("round", "Round off", "RoundOff", 40)]));
        var preview = Calculate(review);
        Assert.Equal(9660, preview.DifferencePaise);
        Assert.Equal(193000, preview.Shares["a"]);
        Assert.Equal("receipt_reconciliation_required", Assert.Throws<DomainException>(() => Calculate(review with { Merchant = "Changed" })).Code);
        Assert.Equal(preview.ReviewHash, ReceiptSplitEngine.Hash(review with { Items = review.Items.Select(i => i with { AssigneeIds = i.AssigneeIds.Reverse().ToArray() }).ToArray() }));
    }

    [Fact]
    public void IgnoringPositiveItemsOrLeavingItemsUnassignedIsRejected()
    {
        Assert.Equal("receipt_items_invalid", Assert.Throws<DomainException>(() => Calculate(Review(100, [Item("one", 100, "a") with { Ignored = true }]))).Code);
        Assert.Equal("receipt_unassigned_items", Assert.Throws<DomainException>(() => Calculate(Review(100, [Item("one", 100)]))).Code);
        Assert.Equal("receipt_unassigned_items", Assert.Throws<DomainException>(() => Calculate(Review(100, [Item("one", 100, "a"), Item("free", 0)]))).Code);
        Assert.Equal(100, Calculate(Review(100, [Item("one", 100, "a"), Item("free", 0) with { Ignored = true }])).Shares["a"]);
    }

    [Fact]
    public void ZeroSubtotalAndImpossibleDiscountOverridesRequireDifferentSplit()
    {
        Assert.Equal("receipt_zero_subtotal", Assert.Throws<DomainException>(() => Calculate(Review(1, [Item("zero", 0, "a")]))).Code);
        Assert.Equal("receipt_discount_exceeds_share", Assert.Throws<DomainException>(() => Calculate(Review(99,
            [Item("a", 1, "a"), Item("b", 100, "b")], [new("discount", "Discount", "Discount", -2, Weights: new Dictionary<string, long> { ["a"] = 1 })]))).Code);
        Assert.Equal("receipt_zero_weights", Assert.Throws<DomainException>(() => Calculate(Review(101,
            [Item("a", 100, "a")], [new("tax", "Tax", "Tax", 1, Weights: new Dictionary<string, long> { ["a"] = 0 })]))).Code);
    }

    [Fact]
    public void ForeignCurrencyRequiresExplicitHashBoundConversionAndPreservedSourcePrecision()
    {
        var review = Review(1200, [Item("one", 1200, "a") with { SourceLineTotal = "4.123", SourceUnitPrice = "4.123" }]) with
        { SourceCurrency = "KWD", SourceGrandTotal = "4.123" };
        Assert.Equal("receipt_currency_mismatch", Assert.Throws<DomainException>(() => Calculate(review)).Code);
        review = review with { ConvertedToInr = true };
        Assert.Equal(1200, Calculate(Confirm(review)).Shares["a"]);
        Assert.Equal("receipt_currency_mismatch", Assert.Throws<DomainException>(() => Calculate(Confirm(review with { Items = [review.Items[0] with { SourceLineTotal = null }] }))).Code);
    }

    [Fact]
    public void ForeignTotalOnlyConversionNeverComparesOriginalCurrencyWithInr()
    {
        var review = Review(1200, [Item("one", 0) with { SourceLineTotal = "4.123", SourceUnitPrice = "4.123" }]) with
        { SourceCurrency = "KWD", SourceGrandTotal = "4.124", ConvertedToInr = true, SplitByItems = false };
        var preview = Calculate(Confirm(review));
        Assert.Equal(0, preview.DifferencePaise);
        Assert.False(preview.RequiresDifferenceAcknowledgement);
        Assert.Equal("0.001", preview.SourceDifference);
        Assert.Contains("source_reconciliation_mismatch", preview.Warnings);
    }

    [Fact]
    public void GrandTotalOnlyFallbackUsesPrintedSubtotalWhenKnownAndNeverInventsMissingItemAmounts()
    {
        var review = Review(1100, [], [new("tax", "Tax", "Tax", 100)]) with { SplitByItems = false, SubtotalPaise = 1000 };
        var preview = Calculate(review);
        Assert.Equal(1000, preview.ItemSubtotalPaise); Assert.Equal(0, preview.DifferencePaise);
        Assert.Contains("grand_total_only", preview.Warnings);
        Assert.Equal("receipt_reconciliation_required", Assert.Throws<DomainException>(() => Calculate(review with { GrandTotalPaise = 2000 })).Code);
        var manual = Calculate(review with { SubtotalPaise = null, GrandTotalPaise = 2000 });
        Assert.Equal(0, manual.DifferencePaise); Assert.False(manual.RequiresDifferenceAcknowledgement);
        Assert.Contains("grand_total_only", manual.Warnings);
    }

    [Fact]
    public void InvalidOrRemovedMembersDuplicateItemsAndUnboundedQuantitiesAreRejected()
    {
        Assert.Equal("invalid_expense_member", Assert.Throws<DomainException>(() => Calculate(Review(100, [Item("one", 100, "gone")]))).Code);
        Assert.Equal("receipt_items_invalid", Assert.Throws<DomainException>(() => Calculate(Review(100, [Item("one", 100, "a", "a")]))).Code);
        Assert.Equal("receipt_items_invalid", Assert.Throws<DomainException>(() => Calculate(Review(100, [Item("one", 50, "a"), Item("one", 50, "b")]))).Code);
        Assert.Equal("receipt_items_invalid", Assert.Throws<DomainException>(() => Calculate(Review(100, [Item("one", 100, "a") with { Quantity = "1e8" }]))).Code);
        Assert.Contains("quantity_price_mismatch", Calculate(Review(100, [Item("one", 100, "a") with { Quantity = "0.5" }])).Warnings);
    }

    [Fact]
    public void MaximumCartesianReceiptFitsBoundedUtf8RevisionAndConservesAllPaise()
    {
        var ids = Enumerable.Range(0, 50).Select(i => i.ToString().PadLeft(36, 'a')).ToArray();
        var name = string.Concat(Enumerable.Repeat("🧾", 200));
        var items = Enumerable.Range(0, 150).Select(i => new ReceiptItem(i.ToString().PadLeft(36, 'i'), name, "10000.000001",
            10000, 6000000, ids, Transliteration: name, SourceUnitPrice: "999999999999.999999", SourceLineTotal: "999999999999.999999")).ToArray();
        // The quantity limit is 10,000, including decimals.
        items = items.Select(i => i with { Quantity = "10000.000000" }).ToArray();
        var charges = Enumerable.Range(0, 20).Select(i => new ReceiptCharge(i.ToString().PadLeft(36, 'c'), string.Concat(Enumerable.Repeat("🧾", 100)), "Tax", 5000000,
            Weights: ids.ToDictionary(id => id, _ => Money.MaximumExpensePaise), SourceAmount: "999999999999.999999")).ToArray();
        var review = Review(Money.MaximumExpensePaise, items, charges);
        var preview = ReceiptSplitEngine.Calculate(review, ids);
        Assert.Equal(Money.MaximumExpensePaise, preview.Shares.Values.Sum());
        Assert.Equal(50, preview.Shares.Count);
        Assert.All(preview.Shares.Values, v => Assert.Equal(20000000, v));
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new { receiptId = Guid.NewGuid(), revision = 999L, review, shares = preview.Shares, reviewHash = preview.ReviewHash },
            new JsonSerializerOptions(JsonSerializerDefaults.Web) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        Assert.True(bytes.Length <= ReceiptSplitEngine.MaximumRevisionBytes, $"Revision bytes: {bytes.Length}");
    }

    [Fact]
    public void RandomSignedChargesConserveEachComponentAndNeverProduceNegativeShares()
    {
        var random = new Random(4418);
        for (var sample = 0; sample < 500; sample++)
        {
            var a = random.Next(1, 1000); var b = random.Next(1, 1000); var c = random.Next(1, 1000);
            var subtotal = a + b + c; var first = random.Next(subtotal / 3); var second = random.Next(subtotal / 3);
            var tax = random.Next(100); var grandTotal = subtotal + tax - first - second;
            var preview = Calculate(Review(grandTotal, [Item("a", a, "a"), Item("b", b, "b"), Item("c", c, "c")],
                [new("discount1", "Discount", "Discount", -first), new("tax", "Tax", "Tax", tax), new("discount2", "Discount", "Discount", -second)]));
            Assert.Equal(grandTotal, preview.Shares.Values.Sum());
            Assert.All(preview.Shares.Values, amount => Assert.True(amount >= 0));
            Assert.Equal(-first, preview.People.Sum(p => p.Charges.Single(x => x.Id == "discount1").AmountPaise));
            Assert.Equal(-second, preview.People.Sum(p => p.Charges.Single(x => x.Id == "discount2").AmountPaise));
            Assert.Equal(tax, preview.People.Sum(p => p.Charges.Single(x => x.Id == "tax").AmountPaise));
        }
    }
}
