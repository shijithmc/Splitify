using System.Globalization;
using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Hisaab.Application.Storage;

namespace Hisaab.Infrastructure.Storage;

public sealed class DynamoDbAtomicStore(IAmazonDynamoDB client, string tableName) : IAtomicStore
{
    public async Task<StoreRow?> GetAsync(string pk, string sk, CancellationToken ct = default)
    {
        StoreValidation.Key(pk, sk);
        var result = await client.GetItemAsync(new GetItemRequest
        {
            TableName = tableName,
            Key = Key(pk, sk),
            ConsistentRead = true
        }, ct);
        return result.Item is null || result.Item.Count == 0 ? null : ReadRow(result.Item);
    }

    public async Task<StorePage> QueryAsync(string pk, string prefix, int limit = 100, string? cursor = null, CancellationToken ct = default)
    {
        StoreValidation.Query(pk, prefix, limit);
        var lastSk = StoreCursor.Decode(cursor, pk, prefix);
        var request = new QueryRequest
        {
            TableName = tableName,
            ConsistentRead = true,
            Limit = limit,
            KeyConditionExpression = prefix.Length == 0 ? "#pk = :pk" : "#pk = :pk AND begins_with(#sk, :prefix)",
            ExpressionAttributeNames = new() { ["#pk"] = "PK" },
            ExpressionAttributeValues = new() { [":pk"] = new() { S = pk } }
        };
        if (prefix.Length != 0)
        {
            request.ExpressionAttributeNames["#sk"] = "SK";
            request.ExpressionAttributeValues[":prefix"] = new() { S = prefix };
        }
        if (lastSk is not null) request.ExclusiveStartKey = Key(pk, lastSk);
        var result = await client.QueryAsync(request, ct);
        return new(result.Items?.Select(ReadRow).ToArray() ?? [],
            result.LastEvaluatedKey is { Count: > 0 }
                ? StoreCursor.Encode(pk, prefix, result.LastEvaluatedKey["SK"].S) : null);
    }

    public async Task TransactAsync(IReadOnlyList<StoreMutation> mutations, CancellationToken ct = default)
    {
        StoreValidation.Transaction(mutations);
        // Account for full existing items in delete/condition operations as well as submitted puts.
        // Conditional versions below protect against changes after these size reads.
        long bytes = mutations.Where(m => m.Row is not null).Sum(m => (long)StoreValidation.ItemBytes(m.Row!));
        foreach (var mutation in mutations.Where(m => m.Kind != StoreMutationKind.Put))
        {
            var row = await GetAsync(mutation.Key.Pk, mutation.Key.Sk, ct);
            if (row?.Version != mutation.ExpectedVersion) throw new StoreConflictException();
            if (row is not null) bytes += StoreValidation.ItemBytes(row);
        }
        StoreValidation.TransactionBytes(bytes);
        var request = new TransactWriteItemsRequest
        {
            // Stable for AWS SDK transport retries. Durable HTTP idempotency belongs to rows in the transaction.
            ClientRequestToken = Guid.NewGuid().ToString("N"),
            TransactItems = mutations.Select(ToAction).ToList()
        };
        try { await client.TransactWriteItemsAsync(request, ct); }
        catch (TransactionCanceledException ex) when (ex.CancellationReasons?.Any(reason =>
            reason.Code is "ConditionalCheckFailed" or "TransactionConflict") == true)
        {
            throw new StoreConflictException(inner: ex);
        }
        catch (TransactionCanceledException ex) when (ex.CancellationReasons?.Any(reason => reason.Code == "ValidationError") == true)
        {
            throw new StoreValidationException("DynamoDB rejected transaction item sizes or data.");
        }
        catch (TransactionConflictException ex) { throw new StoreConflictException(inner: ex); }
    }

    private TransactWriteItem ToAction(StoreMutation mutation)
    {
        var condition = mutation.ExpectedVersion is null ? "attribute_not_exists(#pk)" : "#version = :version";
        var names = mutation.ExpectedVersion is null
            ? new Dictionary<string, string> { ["#pk"] = "PK" }
            : new Dictionary<string, string> { ["#version"] = "Version" };
        var values = mutation.ExpectedVersion is null ? null : new Dictionary<string, AttributeValue>
        {
            [":version"] = new() { N = mutation.ExpectedVersion.Value.ToString(CultureInfo.InvariantCulture) }
        };
        return mutation.Kind switch
        {
            StoreMutationKind.Put => new()
            {
                Put = new()
                {
                    TableName = tableName,
                    Item = WriteRow(mutation.Row!),
                    ConditionExpression = condition,
                    ExpressionAttributeNames = names,
                    ExpressionAttributeValues = values
                }
            },
            StoreMutationKind.Delete => new()
            {
                Delete = new()
                {
                    TableName = tableName,
                    Key = Key(mutation.Key.Pk, mutation.Key.Sk),
                    ConditionExpression = condition,
                    ExpressionAttributeNames = names,
                    ExpressionAttributeValues = values
                }
            },
            StoreMutationKind.Condition => new()
            {
                ConditionCheck = new()
                {
                    TableName = tableName,
                    Key = Key(mutation.Key.Pk, mutation.Key.Sk),
                    ConditionExpression = condition,
                    ExpressionAttributeNames = names,
                    ExpressionAttributeValues = values
                }
            },
            _ => throw new StoreValidationException("Unsupported transaction action.")
        };
    }

    private static Dictionary<string, AttributeValue> Key(string pk, string sk)
        => new() { ["PK"] = new() { S = pk }, ["SK"] = new() { S = sk } };

    private static Dictionary<string, AttributeValue> WriteRow(StoreRow row)
    {
        var item = Key(row.Pk, row.Sk);
        item["Version"] = new() { N = row.Version.ToString(CultureInfo.InvariantCulture) };
        item["Data"] = new() { S = row.Data.GetRawText() };
        if (row.ExpiresAtUnixSeconds is { } expiry)
            item["ExpiresAt"] = new() { N = expiry.ToString(CultureInfo.InvariantCulture) };
        return item;
    }

    private static StoreRow ReadRow(Dictionary<string, AttributeValue> item)
    {
        using var data = JsonDocument.Parse(item["Data"].S);
        return new(item["PK"].S, item["SK"].S, long.Parse(item["Version"].N, CultureInfo.InvariantCulture),
            data.RootElement.Clone(), item.TryGetValue("ExpiresAt", out var expiry)
                ? long.Parse(expiry.N, CultureInfo.InvariantCulture) : null);
    }
}
