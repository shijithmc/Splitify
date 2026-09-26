using Hisaab.Api.Identity;
using Hisaab.Application.Storage;

namespace Hisaab.Api.Tests;

public sealed class ActivityDetailTests
{
    [Fact]
    public async Task ExpenseChangesReturnAccountingDiffAndResolveCurrentActorName()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var expense = await j.SaveExpense(amount: 12000);
        var expenseId = expense.GetProperty("id").GetString()!;
        await ApiSession.Json(j.Bob.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{expenseId}", j.Expense(expenseId, 15000, 1));
        var activity = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/activity");
        var edit = Assert.Single(activity.GetProperty("items").EnumerateArray(), x => x.GetProperty("kind").GetString() == "expense_updated");
        Assert.Equal("Bob", edit.GetProperty("actorName").GetString());
        Assert.Equal(j.Bob.UserId, edit.GetProperty("actorId").GetString());
        var diff = edit.GetProperty("changes");
        Assert.Equal(12000, diff.GetProperty("before").GetProperty("amountPaise").GetInt64());
        Assert.Equal(15000, diff.GetProperty("after").GetProperty("amountPaise").GetInt64());
        Assert.Equal(1, diff.GetProperty("before").GetProperty("version").GetInt64());
        Assert.Equal(2, diff.GetProperty("after").GetProperty("version").GetInt64());
        Assert.Equal(4000, diff.GetProperty("before").GetProperty("shares").GetProperty(j.BobId).GetInt64());
        Assert.Equal(5000, diff.GetProperty("after").GetProperty("shares").GetProperty(j.BobId).GetInt64());
        var account = (await factory.Store.GetAsync($"USER#{j.Bob.UserId}", "PROFILE"))!;
        await factory.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(account.Pk, account.Sk, account.Version + 1,
            account.Deserialize<UserAccount>() with { DisplayName = "Robert" }), account.Version)]);
        var global = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, "/v1/activity");
        var renamed = Assert.Single(global.GetProperty("items").EnumerateArray(), x => x.GetProperty("kind").GetString() == "expense_updated");
        Assert.Equal("Robert", renamed.GetProperty("actorName").GetString());
        var stored = (await factory.Store.QueryAsync($"GROUP#{j.GroupId}", "EVENT#")).Items.Single(r => r.Data.GetProperty("kind").GetString() == "expense_updated");
        Assert.False(stored.Data.TryGetProperty("actorName", out _));
        Assert.DoesNotContain("\"Bob\"", stored.Data.GetRawText());
        Assert.DoesNotContain("\"Robert\"", stored.Data.GetRawText());
    }

    [Fact]
    public async Task DeletedActorNameIsAnonymizedWithoutErasingAccountingHistory()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var expense = await j.SaveExpense(amount: 12000);
        var id = expense.GetProperty("id").GetString()!;
        await ApiSession.Json(j.Bob.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{id}", j.Expense(id, 9000, 1));
        await ApiSession.Json(j.Bob.Client, HttpMethod.Delete, "/v1/me", new { confirm = true });
        var activity = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/activity");
        var edit = Assert.Single(activity.GetProperty("items").EnumerateArray(), x => x.GetProperty("kind").GetString() == "expense_updated");
        Assert.Equal("Deleted user", edit.GetProperty("actorName").GetString());
        Assert.Equal(12000, edit.GetProperty("changes").GetProperty("before").GetProperty("amountPaise").GetInt64());
        Assert.Equal(9000, edit.GetProperty("changes").GetProperty("after").GetProperty("amountPaise").GetInt64());
    }
}
