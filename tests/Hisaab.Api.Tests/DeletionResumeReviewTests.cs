using System.Net;
using System.Security.Cryptography;
using Hisaab.Api.Identity;
using Hisaab.Application.Storage;
using Hisaab.Domain;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hisaab.Api.Tests;

public sealed class DeletionResumeReviewTests
{
    [Fact]
    public async Task CancellationAfterOneGroupResumesRemainingWorkWithoutRepeatingProviderDeletion()
    {
        var appleRevocations = 0;
        var revenueCatDeletions = 0;
        await using var factory = new ApiFactory
        {
            ProviderResponse = request =>
            {
                if (request.RequestUri!.Host == "appleid.apple.com")
                {
                    Assert.Equal("/auth/revoke", request.RequestUri.AbsolutePath);
                    appleRevocations++;
                }
                else
                {
                    Assert.Equal("api.revenuecat.com", request.RequestUri.Host);
                    Assert.Equal(HttpMethod.Delete, request.Method);
                    revenueCatDeletions++;
                }
                return new HttpResponseMessage(HttpStatusCode.OK);
            }
        };
        var userId = Guid.NewGuid().ToString();
        var friendId = Guid.NewGuid().ToString();
        var pk = $"USER#{userId}";
        using var interruption = new CancellationTokenSource();
        using var signingKey = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var interruptingStore = new CancelAfterMembershipStore(factory.Store, userId, interruption);
        await using var host = factory.WithWebHostBuilder(builder =>
        {
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Hisaab:Auth:apple:PrivateKey"] = signingKey.ExportPkcs8PrivateKeyPem(),
                ["Hisaab:Auth:apple:TeamId"] = "test-team",
                ["Hisaab:Auth:apple:KeyId"] = "test-key"
            }));
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IAtomicStore>();
                services.AddSingleton<IAtomicStore>(interruptingStore);
            });
        });
        var now = DateTimeOffset.UtcNow;
        var identityKey = IdentityService.IdentityKey("apple", "deleting-apple-subject");
        var encryptedRefresh = host.Services.GetRequiredService<TokenProtector>().Protect("apple-refresh-token");
        var rows = new List<StoreRow>
        {
            StoreRow.Create(pk, "PROFILE", 1, new UserAccount(userId, "Deleting person", null, "deleting", now)),
            StoreRow.Create($"USER#{friendId}", "PROFILE", 1, new UserAccount(friendId, "Friend", null, "active", now)),
            StoreRow.Create("WORK#deletion", userId, 1, new AccountDeletionState(userId, now, now.AddDays(30))),
            StoreRow.Create(identityKey, "OWNER", 1, new ProviderIdentity(userId, "apple", "deleting-apple-subject", null, encryptedRefresh, "com.hisaab.service")),
            StoreRow.Create(pk, "IDENTITY#apple", 1, new { key = identityKey })
        };
        var groupIds = Enumerable.Range(0, 3).Select(_ => Guid.NewGuid().ToString()).Order(StringComparer.Ordinal).ToArray();
        var originalBalances = new Dictionary<string, IReadOnlyList<Balance>>();
        foreach (var groupId in groupIds)
        {
            var group = new Group(groupId, "Shared history", GroupType.Home, false, 1, friendId,
                [new("a", userId, "Deleting person"), new("b", friendId, "Friend")], 1);
            var split = SplitEngine.Calculate(200, SplitMode.Equal, [new("a"), new("b")]);
            var expense = new Expense("expense", groupId, "Shared meal", 200, DateOnly.FromDateTime(now.UtcDateTime), "a", SplitMode.Equal,
                [new("a"), new("b")], split.Shares, 1, null, userId, now);
            var balances = LedgerEngine.ApplyExpense(LedgerEngine.Empty(["a", "b"]), expense);
            originalBalances[groupId] = balances;
            rows.Add(StoreRow.Create(pk, $"GROUP#{groupId}", 1, new { groupId }));
            rows.Add(StoreRow.Create($"GROUP#{groupId}", "META", 1, group));
            rows.Add(StoreRow.Create($"GROUP#{groupId}", "EXPENSE#expense", 1, expense));
            foreach (var balance in balances) rows.Add(StoreRow.Create($"GROUP#{groupId}", $"BALANCE#{balance.ParticipantId}", 1, balance));
        }
        for (var i = 0; i < 26; i++)
        {
            var hash = $"session-{i:00}";
            var refresh = $"refresh-{i:00}";
            rows.Add(StoreRow.Create(pk, $"SESSION#{hash}", 1, new { sessionHash = hash }));
            rows.Add(StoreRow.Create($"SESSION#{hash}", "META", 1, new SessionRecord(userId, refresh, now.AddMinutes(30), now.AddDays(30), now)));
            rows.Add(StoreRow.Create($"REFRESH#{refresh}", "META", 1, new { sessionHash = hash }));
        }
        foreach (var chunk in rows.Chunk(90)) await factory.Store.TransactAsync(chunk.Select(row => StoreMutation.Put(row, null)).ToArray());
        var deletion = host.Services.GetRequiredService<AccountDeletionService>();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => deletion.ProcessAsync(userId, interruption.Token));
        Assert.Equal(2, (await factory.Store.QueryAsync(pk, "GROUP#")).Items.Count);
        var checkpoint = (await factory.Store.GetAsync("WORK#deletion", userId))!.Deserialize<AccountDeletionState>();
        Assert.True(checkpoint.RevenueCatDeleted);
        Assert.Contains(identityKey, checkpoint.RevokedProviders!);
        await deletion.ProcessAsync(userId);
        Assert.Equal(1, appleRevocations);
        Assert.Equal(1, revenueCatDeletions);
        Assert.Empty((await factory.Store.QueryAsync(pk, "GROUP#")).Items);
        Assert.Empty((await factory.Store.QueryAsync(pk, "SESSION#")).Items);
        Assert.Null(await factory.Store.GetAsync("WORK#deletion", userId));
        Assert.Equal("deleted", (await factory.Store.GetAsync(pk, "PROFILE"))!.Deserialize<UserAccount>().Status);
        Assert.Null(await factory.Store.GetAsync(identityKey, "OWNER"));
        for (var i = 0; i < 26; i++)
        {
            Assert.Null(await factory.Store.GetAsync($"SESSION#session-{i:00}", "META"));
            Assert.Null(await factory.Store.GetAsync($"REFRESH#refresh-{i:00}", "META"));
        }
        foreach (var groupId in groupIds)
        {
            var group = (await factory.Store.GetAsync($"GROUP#{groupId}", "META"))!.Deserialize<Group>();
            var deleted = group.Members.Single(m => m.Id == "a");
            Assert.Null(deleted.UserId);
            Assert.True(deleted.IsDeleted);
            Assert.Equal("Deleted user", deleted.DisplayName);
            var balances = (await factory.Store.QueryAsync($"GROUP#{groupId}", "BALANCE#")).Items.Select(r => r.Deserialize<Balance>()).ToArray();
            Assert.Equal(originalBalances[groupId].Select(b => b.NetPaise), balances.Select(b => b.NetPaise));
            LedgerEngine.Validate(balances);
        }
    }
}
