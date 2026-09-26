using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Hisaab.Api.Shared;
using Hisaab.Domain;
using Hisaab.Domain.Receipts;

namespace Hisaab.Api.Receipts.Infrastructure;

public static partial class ReceiptExtractionParser
{
    public static ReceiptExtraction Parse(string text, string model)
    {
        try
        {
            if (System.Text.Encoding.UTF8.GetByteCount(text) > 768 * 1024) throw Invalid();
            using var json = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 12 });
            var root = json.RootElement; Shape(root, "classification", "warnings", "document");
            var classification = root.GetProperty("classification").GetString();
            if (classification is not ("bill" or "not_bill" or "unreadable")) throw Invalid();
            var warnings = Array(root, "warnings", 20).Select(v => LimitedText(v, 100) ?? throw Invalid()).ToList();
            if (classification != "bill")
            {
                if (root.GetProperty("document").ValueKind != JsonValueKind.Null) throw Invalid();
                return Result(classification, null, model, warnings);
            }
            var doc = root.GetProperty("document");
            Shape(doc, "merchant", "date", "currency", "subtotal", "grandTotal", "merchantConfidence", "dateConfidence", "totalConfidence", "items", "charges");
            var currency = LimitedText(doc.GetProperty("currency"), 3);
            var total = Amount(doc.GetProperty("grandTotal"), false);
            if (currency is null || !Currency().IsMatch(currency) || total is null || decimal.Parse(total, CultureInfo.InvariantCulture) <= 0)
                return Result("unreadable", null, model, ["total_or_currency_missing"]);
            var foreign = currency != "INR";
            var merchant = LimitedText(doc.GetProperty("merchant"), 200);
            if (string.IsNullOrWhiteSpace(merchant)) { merchant = "Receipt"; warnings.Add("merchant_missing"); }
            if (Confidence(doc.GetProperty("merchantConfidence")) is null or < .8m) warnings.Add("merchant_uncertain");
            var dateText = LimitedText(doc.GetProperty("date"), 10);
            if (!DateOnly.TryParseExact(dateText, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            { date = DateOnly.FromDateTime(DateTimeOffset.UtcNow.ToOffset(TimeSpan.FromMinutes(330)).DateTime); warnings.Add("date_missing_confirm_today"); }
            if (Confidence(doc.GetProperty("dateConfidence")) is null or < .8m) warnings.Add("date_uncertain");
            if (Confidence(doc.GetProperty("totalConfidence")) is null or < .8m) warnings.Add("total_uncertain");
            var subtotal = Amount(doc.GetProperty("subtotal"), false);
            var items = new List<ReceiptItem>();
            foreach (var item in Array(doc, "items", 150))
            {
                Shape(item, "name", "quantity", "unitPrice", "lineTotal", "transliteration", "confidence");
                var name = LimitedText(item.GetProperty("name"), 200);
                var qty = LimitedText(item.GetProperty("quantity"), 20);
                if (qty is not null && (!DecimalAmount().IsMatch(qty) || !decimal.TryParse(qty, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var q) || q is <= 0 or > 10000)) throw Invalid();
                var unit = Amount(item.GetProperty("unitPrice"), false); var line = Amount(item.GetProperty("lineTotal"), false);
                var confidence = Confidence(item.GetProperty("confidence"));
                if (name is null || qty is null || unit is null || line is null) { confidence = 0; warnings.Add($"item_{items.Count + 1}_missing_fields"); }
                items.Add(new($"item-{items.Count + 1}", name ?? "Unread item", qty ?? "1", foreign ? 0 : Paise(unit), foreign ? 0 : Paise(line), [], false,
                    confidence, LimitedText(item.GetProperty("transliteration"), 200), foreign ? unit : null, foreign ? line : null));
            }
            var charges = new List<ReceiptCharge>();
            foreach (var charge in Array(doc, "charges", 20))
            {
                Shape(charge, "name", "kind", "amount", "included", "confidence");
                var kind = charge.GetProperty("kind").GetString();
                if (kind is not ("Tax" or "Service" or "Discount" or "Tip" or "RoundOff" or "Other")) throw Invalid();
                var amount = Amount(charge.GetProperty("amount"), true); var confidence = Confidence(charge.GetProperty("confidence"));
                if (amount is null) { confidence = 0; warnings.Add($"charge_{charges.Count + 1}_missing_amount"); }
                var paise = foreign ? 0 : Paise(amount);
                if (kind == "Discount" && paise > 0) throw Invalid();
                charges.Add(new($"charge-{charges.Count + 1}", LimitedText(charge.GetProperty("name"), 100) ?? kind, kind, paise,
                    charge.GetProperty("included").GetBoolean(), null, confidence, foreign ? amount : null));
            }
            if (foreign) warnings.Add("manual_inr_conversion_required");
            var review = new ReceiptReview(merchant, date, currency, foreign ? 0 : Paise(total), items, charges,
                SourceGrandTotal: foreign ? total : null, SubtotalPaise: foreign || subtotal is null ? null : Paise(subtotal), SourceSubtotal: foreign ? subtotal : null);
            return Result("bill", JsonSerializer.SerializeToElement(review, JsonDefaults.Options), model, warnings.Distinct().ToArray());
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException or OverflowException or KeyNotFoundException or ArgumentException)
        { throw Invalid(); }
    }
    private static ReceiptExtraction Result(string classification, JsonElement? document, string model, IReadOnlyList<string> warnings) => new(classification, document, model, ReceiptExtractionSchema.PromptVersion, ReceiptExtractionSchema.Version, warnings);
    private static void Shape(JsonElement value, params string[] expected)
    {
        if (value.ValueKind != JsonValueKind.Object) throw Invalid();
        var actual = value.EnumerateObject().Select(p => p.Name).ToArray();
        if (actual.Length != expected.Length || actual.Distinct(StringComparer.Ordinal).Count() != actual.Length || actual.Any(n => !expected.Contains(n, StringComparer.Ordinal))) throw Invalid();
    }
    private static JsonElement[] Array(JsonElement element, string field, int maximum)
    {
        var array = element.GetProperty(field); if (array.ValueKind != JsonValueKind.Array || array.GetArrayLength() > maximum) throw Invalid(); return array.EnumerateArray().ToArray();
    }
    private static string? LimitedText(JsonElement value, int max)
    {
        if (value.ValueKind == JsonValueKind.Null) return null;
        var result = value.GetString(); if (result is null || result.EnumerateRunes().Count() > max || result.Any(c => char.IsControl(c) && c != '\n' && c != '\t')) throw Invalid(); return result;
    }
    private static string? Amount(JsonElement value, bool signed)
    {
        var text = LimitedText(value, 20); if (text is null) return null;
        if (!DecimalAmount().IsMatch(text) || !decimal.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var amount) || Math.Abs(amount) > 10_000_000m || (!signed && amount < 0)) throw Invalid();
        return text;
    }
    private static long Paise(string? text)
    {
        if (text is null) return 0;
        var scaled = decimal.Parse(text, CultureInfo.InvariantCulture) * 100;
        if (scaled != decimal.Truncate(scaled) || Math.Abs(scaled) > Money.MaximumExpensePaise) throw Invalid();
        return checked((long)scaled);
    }
    private static decimal? Confidence(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Null) return null;
        if (!value.TryGetDecimal(out var confidence) || confidence is < 0 or > 1) throw Invalid(); return confidence;
    }
    private static ReceiptProviderException Invalid() => new("receipt_provider_invalid_output", false);
    [GeneratedRegex("^-?[0-9]{1,12}(\\.[0-9]{1,6})?$", RegexOptions.CultureInvariant)] private static partial Regex DecimalAmount();
    [GeneratedRegex("^[A-Z]{3}$", RegexOptions.CultureInvariant)] private static partial Regex Currency();
}
