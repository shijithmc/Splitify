using System.Text.Json;

namespace Hisaab.Api.Tests;

internal sealed record GroupJourney(ApiSession Alice, ApiSession Bob, string GroupId, string AliceId, string BobId, string ThirdId)
{
    public string GroupPath => $"/v1/groups/{GroupId}";

    public static async Task<GroupJourney> Create(ApiFactory factory, bool claim = true)
    {
        var alice = await ApiSession.Login(factory, "Alice");
        var bob = await ApiSession.Login(factory, "Bob");
        var group = await ApiSession.Json(alice.Client, HttpMethod.Post, "/v1/groups", new { name = "Weekend trip", type = "Trip" });
        var gid = group.GetProperty("id").GetString()!;
        var aid = group.GetProperty("members")[0].GetProperty("id").GetString()!;
        var b = await ApiSession.Json(alice.Client, HttpMethod.Post, $"/v1/groups/{gid}/members", new { displayName = "Bob placeholder", phone = "+919900001111" });
        var bid = b.GetProperty("id").GetString()!;
        var third = await ApiSession.Json(alice.Client, HttpMethod.Post, $"/v1/groups/{gid}/members", new { displayName = "Charlie" });
        var result = new GroupJourney(alice, bob, gid, aid, bid, third.GetProperty("id").GetString()!);
        if (claim) await result.ClaimBob();
        return result;
    }

    public async Task<JsonElement> ClaimBob()
    {
        var invite = await ApiSession.Json(Alice.Client, HttpMethod.Post, $"{GroupPath}/invites", new { participantId = BobId });
        return await ApiSession.Json(Bob.Client, HttpMethod.Post, "/v1/invites/accept", new { token = invite.GetProperty("token").GetString() });
    }

    public object Expense(string? id = null, long amount = 10000, long version = 0, string mode = "Equal", long[]? values = null)
    {
        var participants = new[] { AliceId, BobId, ThirdId }.Select((participantId, i) => new { participantId, value = values?[i] ?? 0 });
        return new
        {
            id = id ?? Guid.NewGuid().ToString(),
            description = "Dinner",
            amountPaise = amount,
            date = "2026-09-26",
            payerId = AliceId,
            mode,
            participants,
            version
        };
    }

    public async Task<JsonElement> SaveExpense(string? id = null, long amount = 10000) =>
        await ApiSession.Json(Alice.Client, HttpMethod.Post, $"{GroupPath}/expenses", Expense(id, amount));

    public async Task<Dictionary<string, long>> Nets() => (await ApiSession.Json(Alice.Client, HttpMethod.Get, GroupPath))
        .GetProperty("balances").EnumerateArray().ToDictionary(b => b.GetProperty("participantId").GetString()!, b => b.GetProperty("netPaise").GetInt64());
}
