using System.Security.Cryptography;
using System.Text;
using Hisaab.Domain;
using Hisaab.Domain.Receipts;

namespace Hisaab.Api.Receipts;

public static class ReceiptFingerprint
{
    public static string Prefix(ReceiptReview review, IConfiguration configuration)
    {
        if (string.IsNullOrWhiteSpace(review.Merchant) || review.Merchant.EnumerateRunes().Count() > 200 || review.Date == default ||
            review.SourceCurrency is null || review.SourceCurrency.Length != 3 || review.SourceCurrency.Any(c => c is < 'A' or > 'Z'))
            throw new DomainException(422, "receipt_invalid", "Review merchant, date and source currency before checking duplicates.");
        if (review.SourceCurrency == "INR") Money.RequireExpenseAmount(review.GrandTotalPaise);
        else if (review.SourceGrandTotal is null || review.SourceGrandTotal.Length > 20 || !decimal.TryParse(review.SourceGrandTotal,
                     System.Globalization.NumberStyles.AllowDecimalPoint, System.Globalization.CultureInfo.InvariantCulture, out var original) || original <= 0)
            throw new DomainException(422, "receipt_invalid", "Review the original total before checking duplicates.");
        byte[] key;
        try { key = Convert.FromBase64String(configuration["Hisaab:EncryptionKey"] ?? ""); }
        catch (FormatException) { throw new DomainException(503, "encryption_unconfigured", "Secure receipt lookup is not configured."); }
        if (key.Length != 32) throw new DomainException(503, "encryption_unconfigured", "Secure receipt lookup is not configured.");
        var merchant = string.Join(' ', review.Merchant.Normalize(NormalizationForm.FormKC).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)).ToUpperInvariant();
        var amount = review.SourceCurrency == "INR" ? review.GrandTotalPaise.ToString(System.Globalization.CultureInfo.InvariantCulture)
            : decimal.Parse(review.SourceGrandTotal!, System.Globalization.CultureInfo.InvariantCulture).ToString("0.######", System.Globalization.CultureInfo.InvariantCulture);
        var value = $"receipt-duplicate-v1\n{merchant}\n{review.Date:yyyy-MM-dd}\n{review.SourceCurrency}\n{amount}";
        return "RECEIPT_DUP#" + Convert.ToHexString(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(value))).ToLowerInvariant() + "#";
    }
}
