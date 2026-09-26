using System.Net;
using System.Net.Http.Headers;
using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;

namespace Hisaab.Api.Tests;

public sealed class IdentityJourneyTests
{
    [Fact]
    public async Task RefreshRotatesBothCredentialsAndRejectsReuse()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var refreshed = await ApiSession.Json(factory.CreateClient(), HttpMethod.Post, "/v1/auth/refresh", new { refreshToken = user.RefreshToken });
        await ApiSession.Error(user.Client, HttpMethod.Get, "/v1/me", HttpStatusCode.Unauthorized);
        await ApiSession.Error(factory.CreateClient(), HttpMethod.Post, "/v1/auth/refresh", HttpStatusCode.Unauthorized, new { refreshToken = user.RefreshToken });
        user.Client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", refreshed.GetProperty("accessToken").GetString());
        var me = await ApiSession.Json(user.Client, HttpMethod.Get, "/v1/me");
        Assert.Equal(user.UserId, me.GetProperty("user").GetProperty("id").GetString());
    }

    [Fact]
    public async Task SignOutRevokesAccessRefreshAndSessionDevices()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        await ApiSession.Json(user.Client, HttpMethod.Post, "/v1/devices", new { id = Guid.NewGuid().ToString(), token = "test-token", platform = "android" });
        using var signOut = await ApiSession.Send(user.Client, HttpMethod.Post, "/v1/auth/sign-out");
        Assert.Equal(HttpStatusCode.NoContent, signOut.StatusCode);
        await ApiSession.Error(user.Client, HttpMethod.Get, "/v1/me", HttpStatusCode.Unauthorized);
        await ApiSession.Error(factory.CreateClient(), HttpMethod.Post, "/v1/auth/refresh", HttpStatusCode.Unauthorized, new { refreshToken = user.RefreshToken });
        Assert.Empty((await factory.Store.QueryAsync($"USER#{user.UserId}", "DEVICE#")).Items);
    }

    [Fact]
    public async Task PreferencesAreIndependentAndPersist()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        await ApiSession.Json(user.Client, HttpMethod.Patch, "/v1/me/preferences", new { expenses = false, payments = true, invites = false });
        var me = await ApiSession.Json(user.Client, HttpMethod.Get, "/v1/me");
        var prefs = me.GetProperty("preferences");
        Assert.False(prefs.GetProperty("expenses").GetBoolean());
        Assert.True(prefs.GetProperty("payments").GetBoolean());
        Assert.False(prefs.GetProperty("invites").GetBoolean());
    }

    [Fact]
    public async Task AccountDeletionRevokesCredentialsAndPreservesFriendsBalances()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        await j.SaveExpense(amount: 12000);
        var before = await j.Nets();
        await ApiSession.Error(j.Bob.Client, HttpMethod.Delete, "/v1/me", HttpStatusCode.UnprocessableEntity, new { confirm = false });
        await ApiSession.Json(j.Bob.Client, HttpMethod.Delete, "/v1/me", new { confirm = true });
        await ApiSession.Error(j.Bob.Client, HttpMethod.Get, "/v1/me", HttpStatusCode.Unauthorized);
        await ApiSession.Error(factory.CreateClient(), HttpMethod.Post, "/v1/auth/refresh", HttpStatusCode.Unauthorized, new { refreshToken = j.Bob.RefreshToken });
        Assert.Equal(before, await j.Nets());
        var group = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        var deleted = group.GetProperty("members").EnumerateArray().Single(m => m.GetProperty("id").GetString() == j.BobId);
        Assert.Equal("Deleted user", deleted.GetProperty("displayName").GetString());
        Assert.True(deleted.GetProperty("isDeleted").GetBoolean());
    }

    [Theory]
    [InlineData("Production", true)]
    [InlineData("Development", false)]
    public async Task DevelopmentLoginRequiresBothEnvironmentAndExplicitFlag(string environment, bool devAuth)
    {
        await using var factory = new ApiFactory(environment, devAuth);
        await ApiSession.Error(factory.CreateClient(), HttpMethod.Post, "/v1/auth/dev", HttpStatusCode.NotFound, new { displayName = "Alice" });
    }

    [Fact]
    public async Task MissingAndForgedBearerTokensCannotReadPrivateData()
    {
        await using var factory = new ApiFactory();
        var client = factory.CreateClient();
        await ApiSession.Error(client, HttpMethod.Get, "/v1/groups", HttpStatusCode.Unauthorized);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", new string('f', 64));
        await ApiSession.Error(client, HttpMethod.Get, "/v1/me", HttpStatusCode.Unauthorized);
    }
    [Fact]
    public async Task ConcurrentRefreshHasExactlyOneWinner()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var statuses = await Task.WhenAll(Enumerable.Range(0, 2).Select(async _ =>
        {
            using var response = await ApiSession.Send(factory.CreateClient(), HttpMethod.Post, "/v1/auth/refresh", new { refreshToken = user.RefreshToken });
            return response.StatusCode;
        }));
        Assert.Single(statuses, s => s == HttpStatusCode.OK);
        Assert.Single(statuses, s => s == HttpStatusCode.Unauthorized);
    }

    [Fact]
    public async Task ExpiredAccessCanRefreshWithinRefreshWindow()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        var token = user.Client.DefaultRequestHeaders.Authorization!.Parameter!;
        var row = (await factory.Store.GetAsync($"SESSION#{Ids.Hash(token)}", "META"))!;
        var session = row.Deserialize<SessionRecord>() with { AccessExpiresAt = DateTimeOffset.UtcNow.AddMinutes(-1) };
        await factory.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, row.Version + 1, session), row.Version)]);
        await ApiSession.Error(user.Client, HttpMethod.Get, "/v1/me", HttpStatusCode.Unauthorized);
        var refreshed = await ApiSession.Json(factory.CreateClient(), HttpMethod.Post, "/v1/auth/refresh", new { refreshToken = user.RefreshToken });
        Assert.Equal(user.UserId, refreshed.GetProperty("user").GetProperty("id").GetString());
    }

    [Fact]
    public async Task SignOutAfterRefreshRemovesPreviouslyRegisteredDevice()
    {
        await using var factory = new ApiFactory();
        var user = await ApiSession.Login(factory, "Alice");
        await ApiSession.Json(user.Client, HttpMethod.Post, "/v1/devices", new { id = Guid.NewGuid().ToString(), token = "old-session-push-token", platform = "android" });
        var refreshed = await ApiSession.Json(factory.CreateClient(), HttpMethod.Post, "/v1/auth/refresh", new { refreshToken = user.RefreshToken });
        user.Client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", refreshed.GetProperty("accessToken").GetString());
        using var response = await ApiSession.Send(user.Client, HttpMethod.Post, "/v1/auth/sign-out");
        Assert.Equal(HttpStatusCode.NoContent, response.StatusCode);
        Assert.Empty((await factory.Store.QueryAsync($"USER#{user.UserId}", "DEVICE#")).Items);
    }

    [Fact]
    public async Task MissingAuthenticationFieldsReturnClientErrors()
    {
        await using var factory = new ApiFactory();
        var client = factory.CreateClient();
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/refresh", HttpStatusCode.Unauthorized, new { refreshToken = (string?)null });
        var challenge = await ApiSession.Json(client, HttpMethod.Get, "/v1/auth/challenge");
        await ApiSession.Error(client, HttpMethod.Post, "/v1/auth/sign-in", HttpStatusCode.BadRequest,
            new { provider = (string?)null, idToken = "invalid", nonce = challenge.GetProperty("nonce").GetString() });
    }

}
