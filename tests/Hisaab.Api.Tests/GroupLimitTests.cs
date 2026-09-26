using System.Net;

namespace Hisaab.Api.Tests;

public sealed class GroupLimitTests
{
    [Fact]
    public async Task ConcurrentFiftiethAndFiftyFirstMemberOnlyRetainFiftyIdentities()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        for (var i = 3; i < 49; i++)
            await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/members", new { displayName = $"Participant {i}" });
        var statuses = await Task.WhenAll(Enumerable.Range(49, 2).Select(async i =>
        {
            using var response = await ApiSession.Send(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/members", new { displayName = $"Participant {i}" });
            return response.StatusCode;
        }));
        Assert.Single(statuses, s => (int)s >= 200 && (int)s < 300);
        Assert.Single(statuses, s => s == HttpStatusCode.UnprocessableEntity);
        var group = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        Assert.Equal(50, group.GetProperty("members").GetArrayLength());
        var participants = group.GetProperty("members").EnumerateArray().Select(m => new { participantId = m.GetProperty("id").GetString(), value = 0 }).ToArray();
        var expense = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", new
        {
            id = Guid.NewGuid().ToString(),
            description = "All fifty participants",
            amountPaise = 5000,
            date = "2026-09-26",
            payerId = j.AliceId,
            mode = "Equal",
            participants
        });
        Assert.Equal(50, expense.GetProperty("shares").EnumerateObject().Count());
        var nets = await j.Nets();
        Assert.Equal(4900, nets[j.AliceId]);
        Assert.Equal(0, nets.Values.Sum());
    }

    [Fact]
    public async Task SplitPreviewDisplaysEligibleRoundingOrder()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var preview = await ApiSession.Json(user.Client, HttpMethod.Post, "/v1/splits/preview", new
        {
            amountPaise = 1,
            mode = "Percentage",
            participants = new[] { new { participantId = "a", value = 0 }, new { participantId = "c", value = 5000 }, new { participantId = "b", value = 5000 } }
        });
        Assert.Equal(0, preview.GetProperty("shares").GetProperty("a").GetInt64());
        Assert.Equal(1, preview.GetProperty("shares").GetProperty("b").GetInt64());
        Assert.Equal(new[] { "b", "c" }, preview.GetProperty("roundingOrder").EnumerateArray().Select(x => x.GetString()).ToArray());
    }
}
