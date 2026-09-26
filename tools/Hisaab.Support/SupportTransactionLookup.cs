using Hisaab.Api.Shared;
using Hisaab.Application.Storage;

namespace Hisaab.Support;

public sealed class SupportTransactionLookup(IAtomicStore store)
{
    public async Task<TransactionLookupResult?> FindAsync(string provider, string transactionId, CancellationToken ct = default)
    {
        provider = provider.ToUpperInvariant();
        if (provider is not ("APP_STORE" or "PLAY_STORE"))
            throw new ArgumentException("STORE must be APP_STORE or PLAY_STORE.", nameof(provider));
        if (string.IsNullOrWhiteSpace(transactionId) || transactionId.Length > 1024 || transactionId.Any(char.IsControl))
            throw new ArgumentException("TRANSACTION_ID must contain 1–1024 characters and no control characters.", nameof(transactionId));
        var row = await store.GetAsync($"STORE#{provider}#{Ids.Hash(transactionId)}", "OWNER", ct);
        if (row is null) return null;
        if (!row.Data.TryGetProperty("userId", out var userId) || userId.ValueKind != System.Text.Json.JsonValueKind.String || !Guid.TryParse(userId.GetString(), out _))
            throw new InvalidDataException("Stored transaction attribution has an invalid account ID.");
        if (!row.Data.TryGetProperty("provider", out var storedProvider) || storedProvider.ValueKind != System.Text.Json.JsonValueKind.String || storedProvider.GetString() != provider)
            throw new InvalidDataException("Stored transaction attribution does not match the selected store.");
        return new(userId.GetString()!, provider, row.Data.TryGetProperty("eventId", out var eventId) ? eventId.GetString() : null);
    }
}
