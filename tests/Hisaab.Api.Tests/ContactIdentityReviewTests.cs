using System.Net.Http.Headers;
using Hisaab.Api.Identity;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hisaab.Api.Tests;

public sealed class ContactIdentityReviewTests
{
    [Fact]
    public async Task RenamedVerifiedProviderEmailCannotClaimInvitesForFormerAddress()
    {
        await using var factory = new ApiFactory();
        await using var host = factory.WithWebHostBuilder(builder => builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<IProviderVerifier>();
            services.AddSingleton<IProviderVerifier>(new ContactReviewVerifier());
        }));
        var member = host.CreateClient();
        await SignIn(member, "before-rename");
        await SignIn(member, "after-rename");

        var founder = host.CreateClient();
        var founderSession = await ApiSession.Json(founder, HttpMethod.Post, "/v1/auth/dev", new { displayName = "Founder" });
        founder.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", founderSession.GetProperty("accessToken").GetString());
        var group = await ApiSession.Json(founder, HttpMethod.Post, "/v1/groups", new { name = "New owner's private trip", type = "Trip" });
        await ApiSession.Json(founder, HttpMethod.Post, $"/v1/groups/{group.GetProperty("id").GetString()}/members",
            new { displayName = "New email owner", email = "former@example.org" });

        var currentMember = await ApiSession.Json(founder, HttpMethod.Post, $"/v1/groups/{group.GetProperty("id").GetString()}/members",
            new { displayName = "Current email owner", email = "current@example.org" });
        var invitations = await ApiSession.Json(member, HttpMethod.Get, "/v1/invites");
        var visible = Assert.Single(invitations.GetProperty("items").EnumerateArray());
        Assert.Equal(currentMember.GetProperty("id").GetString(), visible.GetProperty("participantId").GetString());
    }

    private static async Task SignIn(HttpClient client, string token)
    {
        var challenge = await ApiSession.Json(client, HttpMethod.Get, "/v1/auth/challenge");
        var session = await ApiSession.Json(client, HttpMethod.Post, "/v1/auth/sign-in", new
        {
            provider = "google",
            idToken = token,
            nonce = challenge.GetProperty("nonce").GetString(),
            displayName = "Workspace member"
        });
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", session.GetProperty("accessToken").GetString());
    }
}
