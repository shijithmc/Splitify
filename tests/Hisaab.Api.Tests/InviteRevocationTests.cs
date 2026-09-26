using System.Net;
using Hisaab.Api.Ledger;
using Hisaab.Api.Shared;

namespace Hisaab.Api.Tests;

public sealed class InviteRevocationTests
{
    [Fact]
    public async Task RevocationIsDurableIdempotentAndPreventsClaimWithoutChangingDebt()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory, claim: false);
        await j.SaveExpense();
        var before = await j.Nets();
        var invite = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/invites", new { participantId = j.BobId });
        var token = invite.GetProperty("token").GetString()!;
        var key = Guid.NewGuid().ToString();
        var result = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/invites/revoke", new { token }, key);
        Assert.True(result.GetProperty("revoked").GetBoolean());
        var version = (await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath)).GetProperty("version").GetInt64();
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/invites/revoke", new { token }, key);
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/invites/revoke", new { token });
        Assert.Equal(version, (await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath)).GetProperty("version").GetInt64());
        await ApiSession.Error(j.Bob.Client, HttpMethod.Post, "/v1/invites/accept", HttpStatusCode.NotFound, new { token });
        Assert.Equal(before, await j.Nets());
        var stored = (await factory.Store.GetAsync($"INVITE#{Ids.Hash(token)}", "META"))!;
        Assert.NotNull(stored.Deserialize<InviteRecord>().RevokedAt);
        Assert.DoesNotContain(token, stored.Data.GetRawText());
        var activity = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/activity");
        Assert.Single(activity.GetProperty("items").EnumerateArray(), x => x.GetProperty("kind").GetString() == "invite_revoked");
    }

    [Fact]
    public async Task OnlyGroupCreatorCanRevokeAndTokenMustBelongToThatGroup()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var invite = await ApiSession.Json(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/invites", new { participantId = j.ThirdId });
        var token = invite.GetProperty("token").GetString()!;
        await ApiSession.Error(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/invites/revoke", HttpStatusCode.Forbidden, new { token });
        var outsider = await ApiSession.Login(factory, "Outsider");
        await ApiSession.Error(outsider.Client, HttpMethod.Post, $"{j.GroupPath}/invites/revoke", HttpStatusCode.NotFound, new { token });
        var otherGroup = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, "/v1/groups", new { name = "Unrelated group", type = "Home" });
        var wrongPath = $"/v1/groups/{otherGroup.GetProperty("id").GetString()}/invites/revoke";
        var wrongGroup = await ApiSession.Error(j.Alice.Client, HttpMethod.Post, wrongPath, HttpStatusCode.NotFound, new { token });
        var absent = await ApiSession.Error(j.Alice.Client, HttpMethod.Post, wrongPath, HttpStatusCode.NotFound, new { token = new string('f', 64) });
        Assert.Equal(wrongGroup.GetProperty("code").GetString(), absent.GetProperty("code").GetString());
        await ApiSession.Json(outsider.Client, HttpMethod.Post, "/v1/invites/accept", new { token });
    }

    [Fact]
    public async Task ArchivedGroupCannotRevokeAndMissingTokenHasSafeError()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/invites/revoke", HttpStatusCode.NotFound, new { });
        var invite = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/invites", new { });
        var group = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        await ApiSession.Json(j.Alice.Client, HttpMethod.Patch, j.GroupPath, new { version = group.GetProperty("version").GetInt64(), archived = true });
        var error = await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/invites/revoke", HttpStatusCode.Conflict,
            new { token = invite.GetProperty("token").GetString() });
        Assert.Equal("group_archived", error.GetProperty("code").GetString());
    }
}
