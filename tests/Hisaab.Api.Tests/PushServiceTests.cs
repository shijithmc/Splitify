using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Hisaab.Api.Identity;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
using Hisaab.Infrastructure.Storage;
using Microsoft.Extensions.Configuration;

namespace Hisaab.Api.Tests;

public sealed class PushServiceTests
{
    [Fact]
    public async Task PushTargetsParticipantsOnlyAndDeduplicatesEachDevice()
    {
        var (store, outbox) = await SeedAsync();
        using var provider = new FakePushProvider();
        var push = new PushService(store, provider, Config());
        await push.DeliverAsync(outbox);
        await push.DeliverAsync(outbox);
        Assert.Single(provider.Messages);
        var message = provider.Messages[0].GetProperty("message");
        Assert.Equal("b-token", message.GetProperty("token").GetString());
        Assert.Equal("g", message.GetProperty("data").GetProperty("groupId").GetString());
        Assert.DoesNotContain("Secret dinner", provider.Messages[0].GetRawText());
        Assert.DoesNotContain("Private holiday", provider.Messages[0].GetRawText());
        Assert.DoesNotContain("Person B", provider.Messages[0].GetRawText());
        Assert.Equal(1, provider.TokenRequests);
    }

    [Fact]
    public async Task MutedPreferenceAndRevokedSessionPreventAnyProviderRequest()
    {
        var (store, outbox) = await SeedAsync();
        using var provider = new FakePushProvider();
        var push = new PushService(store, provider, new ConfigurationManager());
        await Put(store, "USER#ub", "PREFS", new NotificationPreferences(Expenses: false));
        await push.DeliverAsync(outbox);
        var prefs = (await store.GetAsync("USER#ub", "PREFS"))!;
        await store.TransactAsync([StoreMutation.Delete(prefs.Pk, prefs.Sk, prefs.Version), StoreMutation.Delete("SESSION#b-session", "META", 1)]);
        await push.DeliverAsync(outbox);
        Assert.Empty(provider.Messages);
        Assert.Equal(0, provider.TokenRequests);
    }

    [Fact]
    public async Task MissingCredentialsLeaveEligibleDeliveryPending()
    {
        var (store, outbox) = await SeedAsync();
        using var provider = new FakePushProvider();
        var push = new PushService(store, provider, new ConfigurationManager());
        await Assert.ThrowsAsync<InvalidOperationException>(() => push.DeliverAsync(outbox));
        Assert.NotNull(await store.GetAsync("OUTBOX", outbox.Sk));
        Assert.Empty((await store.QueryAsync("DELIVERY#event", "")).Items);
        Assert.Equal(0, provider.TokenRequests);
    }

    [Fact]
    public async Task ProviderFailureCanRetryAndUnregisteredTokenIsRemoved()
    {
        var (store, outbox) = await SeedAsync();
        using var provider = new FakePushProvider { SendStatus = HttpStatusCode.ServiceUnavailable };
        var push = new PushService(store, provider, Config());
        await Assert.ThrowsAsync<InvalidOperationException>(() => push.DeliverAsync(outbox));
        Assert.NotNull(await store.GetAsync("USER#ub", "DEVICE#b-device"));
        provider.SendStatus = HttpStatusCode.NotFound;
        provider.Unregistered = true;
        await push.DeliverAsync(outbox);
        Assert.Null(await store.GetAsync("USER#ub", "DEVICE#b-device"));
        await push.DeliverAsync(outbox);
        Assert.Equal(2, provider.Messages.Count);
    }

    [Fact]
    public async Task InvalidPayloadDoesNotDeleteValidDevice()
    {
        var (store, outbox) = await SeedAsync();
        using var provider = new FakePushProvider { SendStatus = HttpStatusCode.BadRequest };
        await Assert.ThrowsAsync<InvalidOperationException>(() => new PushService(store, provider, Config()).DeliverAsync(outbox));
        Assert.NotNull(await store.GetAsync("USER#ub", "DEVICE#b-device"));
    }

    [Fact]
    public async Task ConcurrentWorkerCannotSendWhileDeliveryLeaseIsHeld()
    {
        var (store, outbox) = await SeedAsync();
        var sending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var provider = new FakePushProvider
        {
            BeforeSend = async () => { sending.SetResult(); await release.Task; }
        };
        var push = new PushService(store, provider, Config());
        var first = push.DeliverAsync(outbox);
        await sending.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Assert.ThrowsAsync<InvalidOperationException>(() => push.DeliverAsync(outbox));
        release.SetResult();
        await first;
        Assert.Single(provider.Messages);
    }

    [Fact]
    public async Task PersistedRecipientsNotifyRemovedExpenseParticipant()
    {
        var (store, outbox) = await SeedAsync();
        var expenseRow = (await store.GetAsync("GROUP#g", "EXPENSE#e"))!;
        var expense = expenseRow.Deserialize<Expense>();
        var updated = expense with { Participants = [new("a")], Shares = new Dictionary<string, long> { ["a"] = 100 }, Version = 2 };
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create(expenseRow.Pk, expenseRow.Sk, 2, updated), 1)]);
        var stored = StoreRow.Create("OUTBOX", "event", 1, new
        {
            id = "event",
            groupId = "g",
            kind = "expense_updated",
            actorId = "ua",
            description = "expense updated",
            createdAt = DateTimeOffset.UtcNow,
            entityId = "e",
            recipientParticipantIds = new[] { "a", "b" }
        });
        using var provider = new FakePushProvider();
        await new PushService(store, provider, Config()).DeliverAsync(stored);
        Assert.Single(provider.Messages);
        _ = outbox;
    }

    private static async Task<(LocalAtomicStore Store, StoreRow Outbox)> SeedAsync()
    {
        var store = new LocalAtomicStore();
        var now = DateTimeOffset.UtcNow;
        await Put(store, "GROUP#g", "META", new Group("g", "Private holiday", GroupType.Trip, false, 1, "ua",
            [new("a", "ua", "Person A"), new("b", "ub", "Person B"), new("c", "uc", "Person C")]));
        SplitParticipant[] participants = [new("a"), new("b")];
        await Put(store, "GROUP#g", "EXPENSE#e", new Expense("e", "g", "Secret dinner", 100, new DateOnly(2026, 9, 26), "a", SplitMode.Equal,
            participants, SplitEngine.Calculate(100, SplitMode.Equal, participants).Shares, 1, null, "ua", now));
        foreach (var id in new[] { "a", "b", "c" })
        {
            await Put(store, $"USER#u{id}", "PROFILE", new UserAccount($"u{id}", $"Person {id}", null, "active", now));
            await Put(store, $"SESSION#{id}-session", "META", new SessionRecord($"u{id}", "refresh", now.AddMinutes(-1), now.AddDays(30), now));
            await Put(store, $"USER#u{id}", $"DEVICE#{id}-device", new { id = $"{id}-device", token = $"{id}-token", platform = "android", sessionHash = $"{id}-session" });
        }
        var outbox = StoreRow.Create("OUTBOX", "event", 1, new Activity("event", "g", "expense_added", "ua", "expense added", now, "e"));
        await store.TransactAsync([StoreMutation.Put(outbox, null)]);
        return (store, outbox);
    }

    private static IConfiguration Config()
    {
        using var key = RSA.Create(2048);
        return new ConfigurationManager().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Hisaab:Firebase:ServiceAccountJson"] = JsonSerializer.Serialize(new
            {
                type = "service_account",
                project_id = "unit-project",
                client_email = "test@unit-project.iam.gserviceaccount.com",
                private_key_id = "unit-key",
                private_key = key.ExportPkcs8PrivateKeyPem()
            })
        }).Build();
    }
    private static Task Put<T>(IAtomicStore store, string pk, string sk, T data)
        => store.TransactAsync([StoreMutation.Put(StoreRow.Create(pk, sk, 1, data), null)]);

    private sealed class FakePushProvider : HttpMessageHandler, IHttpClientFactory
    {
        private HttpClient? _client;
        public List<JsonElement> Messages { get; } = [];
        public int TokenRequests { get; private set; }
        public HttpStatusCode SendStatus { get; set; } = HttpStatusCode.OK;
        public bool Unregistered { get; set; }
        public Func<Task>? BeforeSend { get; init; }
        public HttpClient CreateClient(string name) => _client ??= new(this, disposeHandler: false);

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.RequestUri!.Host == "oauth2.googleapis.com")
            {
                TokenRequests++;
                Assert.Contains("assertion=", await request.Content!.ReadAsStringAsync(cancellationToken));
                return new(HttpStatusCode.OK) { Content = JsonContent.Create(new { access_token = "fake-access-token", expires_in = 3600 }) };
            }
            Assert.Equal("fcm.googleapis.com", request.RequestUri.Host);
            Assert.Equal("Bearer", request.Headers.Authorization?.Scheme);
            Messages.Add(JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken)).RootElement.Clone());
            if (BeforeSend is not null) await BeforeSend();
            return new(SendStatus)
            {
                Content = Unregistered
                    ? JsonContent.Create(new { error = new { details = new[] { new { errorCode = "UNREGISTERED" } } } })
                    : JsonContent.Create(new { name = "projects/unit-project/messages/fake", error = new { status = "INVALID_ARGUMENT" } })
            };
        }
        protected override void Dispose(bool disposing) { if (disposing) _client?.Dispose(); base.Dispose(disposing); }
    }
}
