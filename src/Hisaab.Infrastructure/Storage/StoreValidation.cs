using System.Text;
using System.Text.Json;
using Hisaab.Application.Storage;

namespace Hisaab.Infrastructure.Storage;

internal static class StoreValidation
{
    internal const int MaximumItemBytes = 400 * 1024;
    internal const int MaximumTransactionBytes = 4 * 1024 * 1024;

    internal static void Key(string pk, string sk)
    {
        if (string.IsNullOrEmpty(pk) || Encoding.UTF8.GetByteCount(pk) > 2048 ||
            string.IsNullOrEmpty(sk) || Encoding.UTF8.GetByteCount(sk) > 1024)
            throw new StoreValidationException("Keys must be nonempty and within DynamoDB key byte limits.");
    }

    internal static void Query(string pk, string prefix, int limit)
    {
        Key(pk, "query");
        if (prefix is null || Encoding.UTF8.GetByteCount(prefix) > 1024 || limit is < 1 or > 1000)
            throw new StoreValidationException("Query prefix must be valid and page size between 1 and 1000.");
    }

    internal static int ItemBytes(StoreRow row)
    {
        // Data is one JSON string in DynamoDB. Attribute names and conservative number/metadata
        // overhead are included so local development never accepts a larger item than AWS.
        return checked(Encoding.UTF8.GetByteCount(row.Pk) + Encoding.UTF8.GetByteCount(row.Sk) +
            Encoding.UTF8.GetByteCount(row.Data.GetRawText()) + 100);
    }

    internal static void Transaction(IReadOnlyList<StoreMutation> mutations)
    {
        if (mutations.Count is < 1 or > 100)
            throw new StoreValidationException("A transaction must contain between 1 and 100 actions.");
        var keys = new HashSet<StoreKey>();
        long bytes = 0;
        foreach (var mutation in mutations)
        {
            Key(mutation.Key.Pk, mutation.Key.Sk);
            if (!keys.Add(mutation.Key))
                throw new StoreValidationException("A transaction cannot target a key more than once, including conditions.");
            if (mutation.ExpectedVersion is <= 0)
                throw new StoreValidationException("Expected versions must be positive; use null to require absence.");
            if (!Enum.IsDefined(mutation.Kind))
                throw new StoreValidationException("Unsupported transaction action.");
            if (mutation.Kind == StoreMutationKind.Put)
            {
                var row = mutation.Row ?? throw new StoreValidationException("Put requires a row.");
                if (row.Pk != mutation.Key.Pk || row.Sk != mutation.Key.Sk ||
                    row.Data.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
                    throw new StoreValidationException("Put row must have matching keys and a JSON value.");
                if (mutation.ExpectedVersion == long.MaxValue || row.Version != (mutation.ExpectedVersion ?? 0) + 1)
                    throw new StoreValidationException("Put version must be exactly one greater than expected version, or 1 for creation.");
                var size = ItemBytes(row);
                if (size > MaximumItemBytes)
                    throw new StoreValidationException("An item exceeds the 400 KiB limit.");
                bytes += size;
            }
            else
            {
                if (mutation.Row is not null)
                    throw new StoreValidationException("Only Put actions may contain a row.");
                bytes += Encoding.UTF8.GetByteCount(mutation.Key.Pk) + Encoding.UTF8.GetByteCount(mutation.Key.Sk) + 100;
            }
        }
        TransactionBytes(bytes);
    }

    internal static void TransactionBytes(long bytes)
    {
        if (bytes > MaximumTransactionBytes)
            throw new StoreValidationException("A transaction exceeds the 4 MiB limit.");
    }
}
