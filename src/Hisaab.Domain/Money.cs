using System.Globalization;

namespace Hisaab.Domain;

public static class Money
{
    public const long MaximumExpensePaise = 1_000_000_000;

    public static long RequireExpenseAmount(long amountPaise)
    {
        if (amountPaise <= 0 || amountPaise > MaximumExpensePaise)
            throw new DomainException(422, "invalid_amount", "Amount must be between ₹0.01 and ₹1,00,00,000.00.");
        return amountPaise;
    }

    // No floating-point conversion: the input contract accepts decimal digits and at most two decimals.
    public static long ParsePaise(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new DomainException(422, "invalid_amount", "Enter an amount with at most two decimal places.");
        var parts = value.Trim().Split('.');
        if (parts.Length > 2 || parts[0].Length == 0 || parts[0].Any(c => c is < '0' or > '9') ||
            (parts.Length == 2 && (parts[1].Length is < 1 or > 2 || parts[1].Any(c => c is < '0' or > '9'))))
            throw new DomainException(422, "invalid_amount", "Enter an amount with at most two decimal places.");
        if (!long.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var rupees) ||
            rupees > MaximumExpensePaise / 100)
            throw new DomainException(422, "invalid_amount", "Amount exceeds ₹1,00,00,000.00.");
        var fraction = parts.Length == 1 ? 0 : int.Parse(parts[1].PadRight(2, '0'), CultureInfo.InvariantCulture);
        return RequireExpenseAmount(checked(rupees * 100 + fraction));
    }

    public static string Format(long paise) => $"₹{((decimal)paise / 100).ToString("0.00", CultureInfo.InvariantCulture)}";
}
