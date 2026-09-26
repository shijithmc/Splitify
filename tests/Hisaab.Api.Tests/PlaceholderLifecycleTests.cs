using System.Net;
using Hisaab.Api.Ledger;
using Hisaab.Application.Storage;
using Hisaab.Domain;

namespace Hisaab.Api.Tests;

public sealed class PlaceholderLifecycleTests
{
    [Fact]
    public void ExternalReviewBecomesDueAtExactlyNinetyDays()
    {
        var now = new DateTimeOffset(2026, 9, 26, 12, 0, 0, TimeSpan.Zero);
        var member = new Member("p", null, "Placeholder", IsPlaceholder: true, CreatedAt: now.AddDays(-90));
        Assert.True(MemberDetail.From(member, now).ExternalReviewDue);
        Assert.False(MemberDetail.From(member with { CreatedAt = member.CreatedAt!.Value.AddTicks(1) }, now).ExternalReviewDue);
        Assert.False(MemberDetail.From(member with { CreatedAt = null }, now).ExternalReviewDue);
        Assert.False(MemberDetail.From(member with { IsExternal = true }, now).ExternalReviewDue);
        Assert.False(MemberDetail.From(member with { UserId = "claimed-account" }, now).ExternalReviewDue);
        Assert.False(MemberDetail.From(member with { IsDeleted = true }, now).ExternalReviewDue);
    }

    [Fact]
    public async Task MarkingExternalPreservesParticipantIdentityExpenseHistoryAndBalances()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var initial = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        var created = initial.GetProperty("members").EnumerateArray().Single(m => m.GetProperty("id").GetString() == j.ThirdId);
        Assert.False(created.GetProperty("externalReviewDue").GetBoolean());
        Assert.InRange(created.GetProperty("createdAt").GetDateTimeOffset(), DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(1));
        await j.SaveExpense(amount: 12000);
        var before = await j.Nets();
        var version = await AgePlaceholder(factory, j);
        var due = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        Assert.True(due.GetProperty("members").EnumerateArray().Single(m => m.GetProperty("id").GetString() == j.ThirdId).GetProperty("externalReviewDue").GetBoolean());
        var key = Guid.NewGuid().ToString();
        var result = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/members/{j.ThirdId}/external", new { version }, key);
        var member = result.GetProperty("members").EnumerateArray().Single(m => m.GetProperty("id").GetString() == j.ThirdId);
        Assert.True(member.GetProperty("isExternal").GetBoolean());
        Assert.False(member.GetProperty("isPlaceholder").GetBoolean());
        Assert.False(member.GetProperty("externalReviewDue").GetBoolean());
        Assert.Equal(version + 1, result.GetProperty("version").GetInt64());
        Assert.Equal(before, await j.Nets());
        var history = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, $"{j.GroupPath}/expenses");
        Assert.Single(history.GetProperty("items").EnumerateArray());
        Assert.Equal(4000, history.GetProperty("items")[0].GetProperty("shares").GetProperty(j.ThirdId).GetInt64());
        var repeated = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/members/{j.ThirdId}/external", new { version }, key);
        Assert.Equal(result.GetRawText(), repeated.GetRawText());
        Assert.Equal(version + 1, (await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath)).GetProperty("version").GetInt64());
    }

    [Fact]
    public async Task MarkingExternalEnforcesCreatorAgeVersionMembershipAndArchiveGuards()
    {
        await using var factory = new ApiFactory();
        var j = await GroupJourney.Create(factory);
        var path = $"{j.GroupPath}/members/{j.ThirdId}/external";
        var group = await ApiSession.Json(j.Alice.Client, HttpMethod.Get, j.GroupPath);
        var version = group.GetProperty("version").GetInt64();
        var early = await ApiSession.Error(j.Alice.Client, HttpMethod.Post, path, HttpStatusCode.Conflict, new { version });
        Assert.Equal("external_review_not_due", early.GetProperty("code").GetString());
        await ApiSession.Error(j.Bob.Client, HttpMethod.Post, path, HttpStatusCode.Forbidden, new { version });
        var outsider = await ApiSession.Login(factory, "Outsider");
        await ApiSession.Error(outsider.Client, HttpMethod.Post, path, HttpStatusCode.NotFound, new { version });
        version = await AgePlaceholder(factory, j);
        var stale = await ApiSession.Error(j.Alice.Client, HttpMethod.Post, path, HttpStatusCode.Conflict, new { version = version - 1 });
        Assert.Equal("version_conflict", stale.GetProperty("code").GetString());
        await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/members/{j.BobId}/external", HttpStatusCode.Conflict, new { version });
        var archived = await ApiSession.Json(j.Alice.Client, HttpMethod.Patch, j.GroupPath, new { version, archived = true });
        var error = await ApiSession.Error(j.Alice.Client, HttpMethod.Post, path, HttpStatusCode.Conflict,
            new { version = archived.GetProperty("version").GetInt64() });
        Assert.Equal("group_archived", error.GetProperty("code").GetString());
    }

    private static async Task<long> AgePlaceholder(ApiFactory factory, GroupJourney journey)
    {
        var row = (await factory.Store.GetAsync($"GROUP#{journey.GroupId}", "META"))!;
        var group = row.Deserialize<Group>();
        group = group with
        {
            Version = group.Version + 1,
            Members = group.Members.Select(m => m.Id == journey.ThirdId
            ? m with { CreatedAt = DateTimeOffset.UtcNow.AddDays(-91) } : m).ToArray()
        };
        await factory.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, row.Version + 1, group), row.Version)]);
        return group.Version;
    }
}
