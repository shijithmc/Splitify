using System.Net;

namespace Hisaab.Api.Tests;

public sealed class SettlementJourneyTests
{
    [Fact]
    public async Task PaymentDisputeReversesExactlyOnceAndOnlyReceiverCanDispute()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        await j.SaveExpense(amount: 12000);
        var before = await j.Nets();
        var payment = await ApiSession.Json(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/settlements",
            new { id = Guid.NewGuid().ToString(), fromId = j.BobId, toId = j.AliceId, amountPaise = 1000, method = "UPI" });
        var pid = payment.GetProperty("id").GetString();
        Assert.Equal(before[j.BobId] + 1000, (await j.Nets())[j.BobId]);
        await ApiSession.Error(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/settlements/{pid}/dispute", HttpStatusCode.Forbidden, new { version = 1 });
        var key = Guid.NewGuid().ToString();
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/settlements/{pid}/dispute", new { version = 1 }, key);
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/settlements/{pid}/dispute", new { version = 1 }, key);
        await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/settlements/{pid}/dispute", HttpStatusCode.Conflict, new { version = 2 });
        Assert.Equal(before, await j.Nets());
    }

    [Fact]
    public async Task LeavingRequiresAcknowledgementButPreservesSettlementAccess()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        await j.SaveExpense(amount: 12000);
        await ApiSession.Error(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/leave", HttpStatusCode.Conflict, new { acknowledgeBalance = false });
        await ApiSession.Json(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/leave", new { acknowledgeBalance = true });
        await ApiSession.Json(j.Bob.Client, HttpMethod.Get, j.GroupPath);
        await ApiSession.Error(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.NotFound, j.Expense());
        await ApiSession.Json(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/settlements",
            new { id = Guid.NewGuid().ToString(), fromId = j.BobId, toId = j.AliceId, amountPaise = 1000, method = "Cash" });
        Assert.Equal(-3000, (await j.Nets())[j.BobId]);
    }

    [Fact]
    public async Task ArchiveBlocksMoneyWritesAndReopenAllowsThem()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var group = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        var archived = await ApiSession.Json(j.Alice.Client, HttpMethod.Patch, j.GroupPath,
            new { version = group.GetProperty("version").GetInt64(), archived = true });
        await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.Conflict, j.Expense());
        await ApiSession.Json(j.Alice.Client, HttpMethod.Patch, j.GroupPath,
            new { version = archived.GetProperty("version").GetInt64(), archived = false });
        await j.SaveExpense();
    }

    [Fact]
    public async Task NonMembersCannotReadOrMutateAnyPrivateGroupSurface()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var outsider = await ApiSession.Login(factory, "Outsider");
        foreach (var suffix in new[] { "", "/expenses", "/settlements", "/activity" })
            await ApiSession.Error(outsider.Client, HttpMethod.Get, j.GroupPath + suffix, HttpStatusCode.NotFound);
        await ApiSession.Error(outsider.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.NotFound, j.Expense());
        await ApiSession.Error(outsider.Client, HttpMethod.Post, $"{j.GroupPath}/invites", HttpStatusCode.NotFound, new { });
    }
    [Fact]
    public async Task CreatorCanDeleteOnlyAfterAllDirectDebtsClear()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var expense = await j.SaveExpense();
        var group = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        var version = group.GetProperty("version").GetInt64();
        await ApiSession.Error(j.Bob.Client, HttpMethod.Delete, j.GroupPath, HttpStatusCode.Forbidden, new { version });
        await ApiSession.Error(j.Alice.Client, HttpMethod.Delete, j.GroupPath, HttpStatusCode.Conflict, new { version });
        await ApiSession.Json(j.Alice.Client, HttpMethod.Delete, $"{j.GroupPath}/expenses/{expense.GetProperty("id").GetString()}", new { version = 1 });
        group = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        await ApiSession.Json(j.Alice.Client, HttpMethod.Delete, j.GroupPath, new { version = group.GetProperty("version").GetInt64() });
        await ApiSession.Error(j.Alice.Client, HttpMethod.Get, j.GroupPath, HttpStatusCode.NotFound);
        Assert.Empty((await ApiSession.Json(j.Bob.Client, HttpMethod.Get, "/v1/groups")).GetProperty("items").EnumerateArray());
    }

}
