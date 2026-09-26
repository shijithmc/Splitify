using System.Net;
using System.Text.Json;

namespace Hisaab.Api.Tests;

public sealed class ExpenseJourneyTests
{
    [Fact]
    public async Task PlaceholderClaimPreservesExistingExpenseAndDebtIdentity()
    {
        await using var factory = new ApiFactory();
        var journey = await GroupJourney.Create(factory, claim: false);
        var expense = await journey.SaveExpense();
        var before = await journey.Nets();
        var claimed = await journey.ClaimBob();
        var bob = claimed.GetProperty("members").EnumerateArray().Single(m => m.GetProperty("id").GetString() == journey.BobId);
        Assert.Equal(journey.Bob.UserId, bob.GetProperty("userId").GetString());
        Assert.False(bob.GetProperty("isPlaceholder").GetBoolean());
        Assert.Equal(before, await journey.Nets());
        var listed = await ApiSession.Json(journey.Bob.Client, HttpMethod.Get, $"{journey.GroupPath}/expenses");
        Assert.Equal(expense.GetProperty("id").GetString(), listed.GetProperty("items")[0].GetProperty("id").GetString());
        var home = await ApiSession.Json(journey.Bob.Client, HttpMethod.Get, "/v1/balances");
        Assert.Equal(before[journey.BobId], home.GetProperty("netPaise").GetInt64());
    }

    [Fact]
    public async Task EqualExpenseEditDeleteAndRestoreKeepBalancesAndHistoryConsistent()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var id = Guid.NewGuid().ToString();
        var created = await j.SaveExpense(id);
        var sorted = new[] { j.AliceId, j.BobId, j.ThirdId }.Order(StringComparer.Ordinal).ToArray();
        for (var index = 0; index < sorted.Length; index++)
            Assert.Equal(index == 0 ? 3334 : 3333, created.GetProperty("shares").GetProperty(sorted[index]).GetInt64());
        Assert.Equal(0, (await j.Nets()).Values.Sum());
        var edit = await ApiSession.Json(j.Bob.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{id}", j.Expense(id, 12000, 1));
        Assert.Equal(2, edit.GetProperty("version").GetInt64());
        var stale = await ApiSession.Error(j.Alice.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{id}", HttpStatusCode.Conflict, j.Expense(id, 15000, 1));
        Assert.Equal("version_conflict", stale.GetProperty("code").GetString());
        Assert.Equal("This expense changed — review latest", stale.GetProperty("message").GetString());
        var beforeDelete = await j.Nets();
        await ApiSession.Json(j.Bob.Client, HttpMethod.Delete, $"{j.GroupPath}/expenses/{id}", new { version = 2 });
        Assert.All((await j.Nets()).Values, value => Assert.Equal(0, value));
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses/{id}/restore", new { version = 3 });
        Assert.Equal(beforeDelete, await j.Nets());
        var activity = await ApiSession.Json(j.Bob.Client, HttpMethod.Get, $"{j.GroupPath}/activity");
        var kinds = activity.GetProperty("items").EnumerateArray().Select(x => x.GetProperty("kind").GetString()).ToArray();
        Assert.Contains("expense_added", kinds);
        Assert.Contains("expense_updated", kinds);
        Assert.Contains("expense_deleted", kinds);
        Assert.Contains("expense_restored", kinds);
    }

    [Theory]
    [InlineData("Exact", 2500, 7500, 0)]
    [InlineData("Percentage", 2500, 7500, 0)]
    [InlineData("Shares", 1, 3, 1)]
    public async Task ServerRecomputesEverySplitMode(string mode, long a, long b, long c)
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var expense = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", j.Expense(mode: mode, values: [a, b, c]));
        var shares = expense.GetProperty("shares");
        Assert.Equal(10000, shares.EnumerateObject().Sum(s => s.Value.GetInt64()));
        Assert.Equal(mode == "Shares" ? 6000 : 7500, shares.GetProperty(j.BobId).GetInt64());
        Assert.Equal(mode == "Shares" ? 2000 : 0, shares.GetProperty(j.ThirdId).GetInt64());
    }

    [Fact]
    public async Task InvalidAllocationHasPreciseGapAndWritesNothing()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var error = await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.UnprocessableEntity,
            j.Expense(mode: "Exact", values: [4000, 4750, 0]));
        Assert.Equal("₹12.50 left to assign", error.GetProperty("message").GetString());
        var expenses = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/expenses");
        Assert.Empty(expenses.GetProperty("items").EnumerateArray());
        Assert.All((await j.Nets()).Values, value => Assert.Equal(0, value));
    }

    [Fact]
    public async Task MutationRetryReturnsOriginalResultAndRejectsDifferentPayload()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var id = Guid.NewGuid().ToString();
        var key = Guid.NewGuid().ToString();
        var body = j.Expense(id);
        var first = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", body, key);
        var second = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", body, key);
        Assert.Equal(first.GetRawText(), second.GetRawText());
        var error = await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.Conflict,
            j.Expense(id, 20000), key);
        Assert.Equal("idempotency_mismatch", error.GetProperty("code").GetString());
        var expenses = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/expenses");
        Assert.Single(expenses.GetProperty("items").EnumerateArray());
    }

    [Fact]
    public async Task MutationsRequireUuidIdempotencyKey()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var error = await ApiSession.Error(user.Client, HttpMethod.Post, "/v1/groups", HttpStatusCode.BadRequest,
            new { name = "Trip", type = "Trip" }, includeKey: false);
        Assert.Equal("idempotency_required", error.GetProperty("code").GetString());
    }

    [Fact]
    public async Task ConcurrentExpenseAddsAndResponseRetriesNeverLoseOrDuplicateMoney()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var operations = Enumerable.Range(0, 12).Select(_ => (Id: Guid.NewGuid().ToString(), Key: Guid.NewGuid().ToString())).ToArray();
        await Task.WhenAll(operations.Select(async operation =>
        {
            var body = j.Expense(operation.Id, 300);
            using var response = await ApiSession.Send(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", body, operation.Key);
            Assert.True(response.IsSuccessStatusCode || response.StatusCode == HttpStatusCode.Conflict,
                $"Unexpected concurrent response: {response.StatusCode} {await response.Content.ReadAsStringAsync()}");
            await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", body, operation.Key);
        }));
        var expenses = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/expenses");
        Assert.Equal(12, expenses.GetProperty("items").GetArrayLength());
        var nets = await j.Nets();
        Assert.Equal(2400, nets[j.AliceId]);
        Assert.Equal(-1200, nets[j.BobId]);
        Assert.Equal(-1200, nets[j.ThirdId]);
    }

    [Fact]
    public async Task ExpensePaginationIsTwentyFiveAndCursorCannotCrossGroups()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        for (var i = 0; i < 26; i++) await j.SaveExpense(amount: 3);
        var first = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/expenses");
        Assert.Equal(25, first.GetProperty("items").GetArrayLength());
        var cursor = first.GetProperty("nextCursor").GetString()!;
        var second = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/expenses?cursor={Uri.EscapeDataString(cursor)}");
        Assert.Single(second.GetProperty("items").EnumerateArray());
        var other = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, "/v1/groups", new { name = "Other", type = "Home" });
        await ApiSession.Error(j.Alice.Client, HttpMethod.Get,
            $"/v1/groups/{other.GetProperty("id").GetString()}/expenses?cursor={Uri.EscapeDataString(cursor)}", HttpStatusCode.BadRequest);
    }
    [Fact]
    public async Task TwoEditorsOfSameVersionProduceOneCommitAndOneConflict()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var id = Guid.NewGuid().ToString();
        await j.SaveExpense(id, 300);
        var outcomes = await Task.WhenAll(new[] { (j.Alice.Client, Amount: 600L), (j.Bob.Client, Amount: 900L) }.Select(async edit =>
        {
            using var response = await ApiSession.Send(edit.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{id}", j.Expense(id, edit.Amount, 1));
            return (response.StatusCode, edit.Amount);
        }));
        Assert.Single(outcomes, x => x.StatusCode == HttpStatusCode.OK);
        Assert.Single(outcomes, x => x.StatusCode == HttpStatusCode.Conflict);
        var winner = outcomes.Single(x => x.StatusCode == HttpStatusCode.OK).Amount;
        var nets = await j.Nets();
        Assert.Equal(winner * 2 / 3, nets[j.AliceId]);
        Assert.Equal(-winner / 3, nets[j.BobId]);
    }

    [Fact]
    public async Task ConcurrentIdenticalIdempotencyKeyCreatesOnlyOneGroup()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var key = Guid.NewGuid().ToString();
        var results = await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => ApiSession.Json(user.Client, HttpMethod.Post,
            "/v1/groups", new { name = "Only once", type = "Home" }, key)));
        Assert.Single(results.Select(x => x.GetProperty("id").GetString()).Distinct());
        var groups = await ApiSession.Json(user.Client, HttpMethod.Get, "/v1/groups");
        Assert.Single(groups.GetProperty("items").EnumerateArray());
    }

}
