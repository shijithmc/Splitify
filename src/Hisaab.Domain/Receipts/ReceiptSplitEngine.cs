using System.Globalization;
using System.Security.Cryptography;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Hisaab.Domain.Receipts;

public static partial class ReceiptSplitEngine
{
    public const int MaximumItems = 150;
    public const int MaximumCharges = 20;
    public const int MaximumRevisionBytes = 1536 * 1024;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static ReceiptPreview Calculate(ReceiptReview review, IReadOnlyCollection<string> activeMemberIds,
        bool requireAcknowledgement = true)
    {
        Validate(review, activeMemberIds);
        var hash = Hash(review);
        var subtotal = review.Items.Count == 0 ? review.SubtotalPaise ?? 0 : review.Items.Sum(i => i.LineTotalPaise);
        var additive = review.Charges.Where(c => !c.IncludedInItemPrices).Sum(c => c.AmountPaise);
        // In a foreign Split total review, documentary source items have no asserted INR equivalents.
        // Only the explicitly converted grand total feeds the ledger; never subtract source values from it.
        var difference = review.SourceCurrency != "INR" && !review.SplitByItems || review.Items.Count == 0 && review.SubtotalPaise is null
            ? 0 : checked(review.GrandTotalPaise - subtotal - additive);
        var needsAcknowledgement = Math.Abs(difference) > 100;
        if (requireAcknowledgement && needsAcknowledgement &&
            (!review.DifferenceAcknowledged || review.AcknowledgedReviewHash != hash))
            throw Error("receipt_reconciliation_required", "Correct the difference or confirm proportional allocation for this exact review.");
        if (review.SourceCurrency != "INR" && requireAcknowledgement &&
            (!review.ConvertedToInr || review.AcknowledgedReviewHash != hash))
            throw Error("receipt_currency_mismatch", "Enter and confirm the manually converted INR amount before saving.");

        var warnings = new List<string>();
        if (review.Items.Count == 0) warnings.Add("grand_total_only");
        string? sourceDifference = null;
        if (review.SourceCurrency != "INR" && review.Items.Count > 0 && review.Items.All(i => i.SourceLineTotal is not null) &&
            review.Charges.Where(c => !c.IncludedInItemPrices).All(c => c.SourceAmount is not null))
        {
            var sourceGap = decimal.Parse(review.SourceGrandTotal!, CultureInfo.InvariantCulture) -
                review.Items.Sum(i => decimal.Parse(i.SourceLineTotal!, CultureInfo.InvariantCulture)) -
                review.Charges.Where(c => !c.IncludedInItemPrices).Sum(c => decimal.Parse(c.SourceAmount!, CultureInfo.InvariantCulture));
            sourceDifference = sourceGap.ToString("0.######", CultureInfo.InvariantCulture);
            if (sourceGap != 0) warnings.Add("source_reconciliation_mismatch");
        }
        if (review.Items.Count > 0 && review.SubtotalPaise is { } printedSubtotal && printedSubtotal != subtotal) warnings.Add("subtotal_mismatch");
        if (review.Items.Any(i => decimal.Parse(i.Quantity, CultureInfo.InvariantCulture) * i.UnitPricePaise != i.LineTotalPaise)) warnings.Add("quantity_price_mismatch");
        if (review.Items.Any(i => i.Confidence is null or < 0.8m) || review.Charges.Any(c => c.Confidence is null or < 0.8m)) warnings.Add("review_uncertain_fields");
        if (!review.SplitByItems)
            return new(hash, subtotal, additive, difference, needsAcknowledgement, new Dictionary<string, long>(), [], warnings, sourceDifference);

        var ids = review.Items.Where(i => !i.Ignored).SelectMany(i => i.AssigneeIds)
            .Concat(review.Charges.Where(c => c.Weights is not null).SelectMany(c => c.Weights!.Keys))
            .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
        var itemComponents = ids.ToDictionary(id => id, _ => new List<ReceiptComponent>(), StringComparer.Ordinal);
        var chargeComponents = ids.ToDictionary(id => id, _ => new List<ReceiptComponent>(), StringComparer.Ordinal);
        var itemTotals = ids.ToDictionary(id => id, _ => 0L, StringComparer.Ordinal);
        foreach (var item in review.Items.Where(i => !i.Ignored).OrderBy(i => i.Id, StringComparer.Ordinal))
        {
            var allocations = Allocate(item.LineTotalPaise, item.AssigneeIds.ToDictionary(id => id, _ => 1L, StringComparer.Ordinal));
            foreach (var (id, amount) in allocations)
            {
                itemTotals[id] += amount;
                itemComponents[id].Add(new(item.Id, amount));
            }
        }
        var totals = new Dictionary<string, long>(itemTotals, StringComparer.Ordinal);
        var components = review.Charges.ToList();
        if (difference != 0) components.Add(new("__difference", "Difference adjustment", "Adjustment", difference));
        // Positive components fund the available balance before signed discounts are applied.
        foreach (var charge in components.Where(c => c.AmountPaise >= 0 || c.IncludedInItemPrices)
                     .Concat(components.Where(c => c.AmountPaise < 0 && !c.IncludedInItemPrices)))
        {
            var weights = charge.Weights ?? itemTotals;
            var allocated = charge.AmountPaise < 0 && !charge.IncludedInItemPrices
                ? AllocateReduction(-charge.AmountPaise, weights, totals)
                : Allocate(Math.Abs(charge.AmountPaise), weights);
            foreach (var id in ids)
            {
                var amount = allocated.GetValueOrDefault(id) * (charge.AmountPaise < 0 ? -1 : 1);
                if (!charge.IncludedInItemPrices) totals[id] = checked(totals[id] + amount);
                chargeComponents[id].Add(new(charge.Id, amount, charge.Kind, charge.IncludedInItemPrices));
            }
        }
        if (totals.Values.Any(v => v < 0) || totals.Values.Sum() != review.GrandTotalPaise)
            throw Error("receipt_split_invalid", "The reviewed amounts cannot produce a valid non-negative split.");
        var people = ids.Select(id => new ReceiptPerson(id, itemTotals[id], totals[id], itemComponents[id], chargeComponents[id])).ToArray();
        return new(hash, subtotal, additive, difference, needsAcknowledgement, totals, people, warnings, sourceDifference);
    }

    public static string Hash(ReceiptReview review)
    {
        // Bind explicit confirmation to all reviewed content, while normalizing unordered maps/assignments.
        var canonical = review with
        {
            DifferenceAcknowledged = false,
            AcknowledgedReviewHash = null,
            Items = review.Items.OrderBy(i => i.Id, StringComparer.Ordinal)
                .Select(i => i with { AssigneeIds = i.AssigneeIds.Order(StringComparer.Ordinal).ToArray() }).ToArray(),
            Charges = review.Charges.Select(c => c with
            {
                Weights = c.Weights is null ? null : new SortedDictionary<string, long>(c.Weights.ToDictionary(x => x.Key, x => x.Value), StringComparer.Ordinal)
            }).ToArray()
        };
        return Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(canonical, Json))).ToLowerInvariant();
    }

    private static void Validate(ReceiptReview review, IReadOnlyCollection<string> activeMemberIds)
    {
        if (review is null || !Text(review.Merchant, 200) || review.Date == default || review.Items is null || review.Charges is null ||
            review.Items.Count > MaximumItems || review.Charges.Count > MaximumCharges)
            throw Error("receipt_invalid", "Review the merchant and provide at most 150 items and 20 charges.");
        Money.RequireExpenseAmount(review.GrandTotalPaise);
        if (review.SourceCurrency is null || !CurrencyPattern().IsMatch(review.SourceCurrency))
            throw Error("receipt_currency_mismatch", "Use a three-letter uppercase source currency.");
        if (review.AcknowledgedReviewHash is not null && (review.AcknowledgedReviewHash.Length != 64 || review.AcknowledgedReviewHash.Any(c => !char.IsAsciiHexDigit(c))) ||
            review.SubtotalPaise is < 0 or > Money.MaximumExpensePaise ||
            !SourceAmount(review.SourceGrandTotal) || !SourceAmount(review.SourceSubtotal) ||
            review.SourceCurrency != "INR" && (review.SourceGrandTotal is null || decimal.Parse(review.SourceGrandTotal, CultureInfo.InvariantCulture) <= 0))
            throw Error("receipt_invalid", "Review the subtotal and original currency amounts.");
        if (review.Items.Any(i => i is null || !Id(i.Id) || !Text(i.Name, 200) ||
            !Quantity(i.Quantity) || i.UnitPricePaise is < 0 or > Money.MaximumExpensePaise ||
            i.LineTotalPaise is < 0 or > Money.MaximumExpensePaise || i.AssigneeIds is null ||
            i.AssigneeIds.Count > GroupRules.MaximumMembers || i.AssigneeIds.Any(id => !Id(id)) ||
            i.AssigneeIds.Distinct(StringComparer.Ordinal).Count() != i.AssigneeIds.Count ||
            i.Confidence is < 0 or > 1 || i.Transliteration is not null && !Text(i.Transliteration, 200) ||
            !SourceAmount(i.SourceUnitPrice) || !SourceAmount(i.SourceLineTotal)) ||
            review.Items.Select(i => i.Id).Distinct(StringComparer.Ordinal).Count() != review.Items.Count)
            throw Error("receipt_items_invalid", "Review item identifiers, names, quantities, amounts and assignments.");
        if (review.Items.Any(i => i.Ignored && i.LineTotalPaise != 0))
            throw Error("receipt_items_invalid", "Only zero-price items can be ignored.");
        if (review.Charges.Any(c => c is null || !Id(c.Id) || c.Id == "__difference" || !Text(c.Name, 100) ||
            c.Kind is not ("Tax" or "Service" or "Discount" or "Tip" or "RoundOff" or "Adjustment" or "Other") ||
            c.AmountPaise < -Money.MaximumExpensePaise || c.AmountPaise > Money.MaximumExpensePaise ||
            c.Confidence is < 0 or > 1 || !SourceAmount(c.SourceAmount) ||
            c.Weights is not null && (c.Weights.Count is < 1 or > GroupRules.MaximumMembers ||
                c.Weights.Any(w => !Id(w.Key) || w.Value is < 0 or > Money.MaximumExpensePaise))) ||
            review.Charges.Select(c => c.Id).Distinct(StringComparer.Ordinal).Count() != review.Charges.Count)
            throw Error("receipt_charges_invalid", "Review charges and their allocation overrides.");
        var participants = review.Items.SelectMany(i => i.AssigneeIds).Concat(review.Charges.Where(c => c.Weights is not null).SelectMany(c => c.Weights!.Keys)).Distinct(StringComparer.Ordinal).ToArray();
        if (participants.Length > GroupRules.MaximumMembers || participants.Any(id => !activeMemberIds.Contains(id, StringComparer.Ordinal)))
            throw Error("invalid_expense_member", "Every receipt assignee must be a current group member.");
        if (review.SplitByItems && review.Items.Any(i => !i.Ignored && i.AssigneeIds.Count == 0))
            throw Error("receipt_unassigned_items", "Assign each item, or explicitly ignore zero-price items.");
        if (review.SplitByItems && (review.Items.Count == 0 || review.Items.Sum(i => i.LineTotalPaise) == 0))
            throw Error("receipt_zero_subtotal", "Split the grand total or enter at least one positive item amount.");
        if (review.SourceCurrency != "INR" && review.SplitByItems &&
            (review.Items.Any(i => i.SourceLineTotal is null || i.SourceUnitPrice is null) || review.Charges.Any(c => c.SourceAmount is null)))
            throw Error("receipt_currency_mismatch", "Preserve original item and charge amounts alongside manually reviewed INR amounts.");
        if (JsonSerializer.SerializeToUtf8Bytes(review, Json).Length > MaximumRevisionBytes)
            throw Error("receipt_too_large", "This reviewed receipt exceeds the supported size.");
    }

    private static Dictionary<string, long> Allocate(long amount, IReadOnlyDictionary<string, long> weights)
    {
        var result = weights.Keys.ToDictionary(id => id, _ => 0L, StringComparer.Ordinal);
        if (amount == 0) return result;
        var eligible = weights.Where(w => w.Value > 0).OrderBy(w => w.Key, StringComparer.Ordinal).ToArray();
        var denominator = eligible.Sum(w => w.Value);
        if (denominator == 0) throw Error("receipt_zero_weights", "Choose a positive allocation weight for this charge.");
        foreach (var (id, weight) in eligible) result[id] = (long)((Int128)amount * weight / denominator);
        var remainder = amount - result.Values.Sum();
        for (var i = 0; i < remainder; i++) result[eligible[i].Key]++;
        return result;
    }

    private static Dictionary<string, long> AllocateReduction(long amount, IReadOnlyDictionary<string, long> weights, IReadOnlyDictionary<string, long> available)
    {
        var result = weights.Keys.ToDictionary(id => id, _ => 0L, StringComparer.Ordinal);
        var eligible = weights.Where(w => w.Value > 0 && available.GetValueOrDefault(w.Key) > 0)
            .ToDictionary(w => w.Key, w => w.Value, StringComparer.Ordinal);
        if (eligible.Keys.Sum(id => available[id]) < amount)
            throw Error("receipt_discount_exceeds_share", "This discount exceeds the assigned people's available amounts. Change its weights or split the grand total.");
        var remaining = amount;
        while (remaining > 0)
        {
            var proposed = Allocate(remaining, eligible);
            foreach (var (id, share) in proposed)
            {
                var assigned = Math.Min(share, available[id] - result[id]);
                result[id] += assigned;
                remaining -= assigned;
                if (result[id] == available[id]) eligible.Remove(id);
            }
        }
        return result;
    }

    private static bool Text(string? value, int maximum) => !string.IsNullOrWhiteSpace(value) && value.EnumerateRunes().Count() <= maximum;
    private static bool Id(string? value) => value is not null && value.Length is > 0 and <= 36 && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_');
    private static bool Quantity(string? value) => value is not null && QuantityPattern().IsMatch(value) && decimal.TryParse(value, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var quantity) && quantity is > 0 and <= 10000;
    private static bool SourceAmount(string? value) => value is null || SourceAmountPattern().IsMatch(value);
    private static DomainException Error(string code, string message) => new(422, code, message);
    [GeneratedRegex("^[A-Z]{3}$", RegexOptions.CultureInvariant)] private static partial Regex CurrencyPattern();
    [GeneratedRegex("^[0-9]{1,5}(\\.[0-9]{1,6})?$", RegexOptions.CultureInvariant)] private static partial Regex QuantityPattern();
    [GeneratedRegex("^-?[0-9]{1,12}(\\.[0-9]{1,6})?$", RegexOptions.CultureInvariant)] private static partial Regex SourceAmountPattern();
}
