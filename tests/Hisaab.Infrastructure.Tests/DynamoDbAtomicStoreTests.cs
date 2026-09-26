using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Amazon.Runtime;
using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;

namespace Hisaab.Infrastructure.Tests;

public sealed class DynamoDbAtomicStoreTests
{
    [Fact]
    public async Task ReadsAndQueriesUseStrongConsistencyAndBoundCursorToPartition()
    {
        using var client = new RecordingDynamoClient();
        var store = new DynamoDbAtomicStore(client, "test-table");
        Assert.Null(await store.GetAsync("group", "expense"));
        Assert.True(client.LastGet!.ConsistentRead);
        Assert.Equal("group", client.LastGet.Key["PK"].S);
        client.QueryResult = new QueryResponse
        {
            Items = [Row("group", "expense#1", 1)],
            LastEvaluatedKey = new() { ["PK"] = new() { S = "group" }, ["SK"] = new() { S = "expense#1" } }
        };
        var page = await store.QueryAsync("group", "expense#", 25);
        Assert.True(client.LastQuery!.ConsistentRead);
        Assert.Equal(25, client.LastQuery.Limit);
        Assert.NotNull(page.NextCursor);
        await store.QueryAsync("group", "expense#", 25, page.NextCursor);
        Assert.Equal("expense#1", client.LastQuery.ExclusiveStartKey["SK"].S);
        await Assert.ThrowsAsync<StoreValidationException>(() => store.QueryAsync("other", "expense#", 25, page.NextCursor));
    }

    [Fact]
    public async Task WriteConditionsLiveOnSameActionAndIndependentChecksStaySeparate()
    {
        using var client = new RecordingDynamoClient();
        client.GetRows[("user", "profile")] = Row("user", "profile", 7);
        var store = new DynamoDbAtomicStore(client, "test-table");
        await store.TransactAsync([
            StoreMutation.Put(StoreRow.Create("group", "expense", 1, new { Amount = 100 }), null),
            StoreMutation.Put(StoreRow.Create("group", "balance", 3, new { Amount = 100 }), 2),
            StoreMutation.Condition("user", "profile", 7)]);
        var actions = client.LastTransaction!.TransactItems;
        Assert.Equal("attribute_not_exists(#pk)", actions[0].Put.ConditionExpression);
        Assert.Equal("#version = :version", actions[1].Put.ConditionExpression);
        Assert.Equal("2", actions[1].Put.ExpressionAttributeValues[":version"].N);
        Assert.Equal("7", actions[2].ConditionCheck.ExpressionAttributeValues[":version"].N);
        Assert.Equal("1", actions[0].Put.Item["Version"].N);
        Assert.Equal("{\"amount\":100}", actions[0].Put.Item["Data"].S);
        Assert.Equal(32, client.LastTransaction.ClientRequestToken.Length);
    }

    [Fact]
    public async Task FrozenActorCheckFailsBeforeSendingWrite()
    {
        using var client = new RecordingDynamoClient();
        client.GetRows[("user", "profile")] = Row("user", "profile", 8);
        await Assert.ThrowsAsync<StoreConflictException>(() => new DynamoDbAtomicStore(client, "test-table").TransactAsync([
            StoreMutation.Condition("user", "profile", 7),
            StoreMutation.Put(StoreRow.Create("group", "expense", 1, new { Amount = 100 }), null)]));
        Assert.Null(client.LastTransaction);
    }

    [Fact]
    public async Task ConditionalFailureBecomesConflictButCapacityFailureRemainsRetryable()
    {
        using var client = new RecordingDynamoClient();
        var mutation = StoreMutation.Put(StoreRow.Create("group", "expense", 1, new { Amount = 100 }), null);
        var store = new DynamoDbAtomicStore(client, "test-table");
        client.TransactionFailure = new TransactionCanceledException("changed")
        {
            CancellationReasons = [new CancellationReason { Code = "ConditionalCheckFailed" }]
        };
        await Assert.ThrowsAsync<StoreConflictException>(() => store.TransactAsync([mutation]));
        client.TransactionFailure = new ProvisionedThroughputExceededException("retry later");
        await Assert.ThrowsAsync<ProvisionedThroughputExceededException>(() => store.TransactAsync([mutation]));
    }

    [Fact]
    public async Task GuardRejectsOversizedOrDuplicateTransactionsBeforeNetwork()
    {
        using var client = new RecordingDynamoClient();
        var mutation = StoreMutation.Put(StoreRow.Create("group", "expense", 1, new { Amount = 100 }), null);
        var store = new DynamoDbAtomicStore(client, "test-table");
        await Assert.ThrowsAsync<StoreValidationException>(() => store.TransactAsync([mutation, mutation]));
        Assert.Null(client.LastGet);
        Assert.Null(client.LastTransaction);
    }

    private static Dictionary<string, AttributeValue> Row(string pk, string sk, long version) => new()
    {
        ["PK"] = new() { S = pk },
        ["SK"] = new() { S = sk },
        ["Version"] = new() { N = version.ToString(System.Globalization.CultureInfo.InvariantCulture) },
        ["Data"] = new() { S = "{\"amount\":100}" }
    };

    private sealed class RecordingDynamoClient() : AmazonDynamoDBClient(new AnonymousAWSCredentials(),
        new AmazonDynamoDBConfig { ServiceURL = "http://localhost:8000" })
    {
        public GetItemRequest? LastGet { get; private set; }
        public QueryRequest? LastQuery { get; private set; }
        public TransactWriteItemsRequest? LastTransaction { get; private set; }
        public Dictionary<(string, string), Dictionary<string, AttributeValue>> GetRows { get; } = [];
        public QueryResponse QueryResult { get; set; } = new();
        public Exception? TransactionFailure { get; set; }

        public override Task<GetItemResponse> GetItemAsync(GetItemRequest request, CancellationToken cancellationToken = default)
        {
            LastGet = request;
            return Task.FromResult(new GetItemResponse { Item = GetRows.GetValueOrDefault((request.Key["PK"].S, request.Key["SK"].S)) });
        }
        public override Task<QueryResponse> QueryAsync(QueryRequest request, CancellationToken cancellationToken = default)
        {
            LastQuery = request;
            return Task.FromResult(QueryResult);
        }
        public override Task<TransactWriteItemsResponse> TransactWriteItemsAsync(TransactWriteItemsRequest request, CancellationToken cancellationToken = default)
        {
            LastTransaction = request;
            return TransactionFailure is null ? Task.FromResult(new TransactWriteItemsResponse())
                : Task.FromException<TransactWriteItemsResponse>(TransactionFailure);
        }
    }
}
