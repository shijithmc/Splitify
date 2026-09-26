using System.Text.Json;
using Hisaab.Application.Storage;

namespace Hisaab.Infrastructure.Storage;

internal sealed record StoreCursor(string Pk, string Prefix, string LastSk)
{
    internal static string Encode(string pk, string prefix, string lastSk)
        => Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new StoreCursor(pk, prefix, lastSk)))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');

    internal static string? Decode(string? cursor, string pk, string prefix)
    {
        if (cursor is null) return null;
        if (cursor.Length is 0 or > 16384) throw new StoreValidationException("Invalid pagination cursor.");
        try
        {
            var base64 = cursor.Replace('-', '+').Replace('_', '/');
            base64 = base64.PadRight((base64.Length + 3) / 4 * 4, '=');
            var value = JsonSerializer.Deserialize<StoreCursor>(Convert.FromBase64String(base64));
            if (value is null || value.Pk != pk || value.Prefix != prefix ||
                string.IsNullOrEmpty(value.LastSk) || !value.LastSk.StartsWith(prefix, StringComparison.Ordinal))
                throw new StoreValidationException("Pagination cursor does not match this query.");
            StoreValidation.Key(pk, value.LastSk);
            return value.LastSk;
        }
        catch (Exception ex) when (ex is FormatException or JsonException)
        {
            throw new StoreValidationException("Invalid pagination cursor.");
        }
    }
}
