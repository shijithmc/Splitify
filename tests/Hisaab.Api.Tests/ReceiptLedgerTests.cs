using System.Net;
using System.Text.Json;
using Hisaab.Api.Contracts;
using Hisaab.Api.Receipts;
using Hisaab.Application.Storage;
using Hisaab.Domain;
using Hisaab.Domain.Receipts;
using Microsoft.Extensions.DependencyInjection;

namespace Hisaab.Api.Tests;

public sealed class ReceiptLedgerTests
{
    private static ReceiptReview Review(GroupJourney j, long amount = 101) => new("Café भोजन", new DateOnly(2026, 9, 26), "INR", amount,
        [new("meal", "Dinner", "1", amount, amount, [j.BobId, j.AliceId])], [], true);

    private static async Task<ReceiptRecord> Seed(ApiFactory factory, GroupJourney j, string state = "manual_ready", bool reserved = false)
    {
        var now = DateTimeOffset.UtcNow; var id = Guid.NewGuid().ToString();
        var record = new ReceiptRecord(id, j.GroupId, j.Alice.UserId, j.AliceId, state, reserved, [],
            [new("image", $"media/{id}/1.jpg", $"media/{id}/1-thumb.jpg", "image/jpeg", 300, new string('a', 64), 500, 1000, 100)],
            now, now.AddDays(7), QuotaMonth: reserved ? ReceiptQuotaService.Month(now) : null, ReservationHeld: reserved,
            Generation: 2, LeaseToken: reserved ? "active-lease" : null, LeaseUntil: reserved ? now.AddMinutes(1) : null);
        var writes = new List<StoreMutation> { StoreMutation.Put(StoreRow.Create($"RECEIPT#{id}", "META", 1, record), null),
            StoreMutation.Put(StoreRow.Create($"USER#{j.Alice.UserId}", $"RECEIPT#{id}", 1, new { receiptId = id }), null) };
        if (reserved) writes.Add(StoreMutation.Put(StoreRow.Create($"USER#{j.Alice.UserId}", $"SCAN_QUOTA#{record.QuotaMonth}", 1, new ReceiptQuota(0, 1)), null));
        await factory.Store.TransactAsync(writes);
        return record;
    }

    private static ExpenseRequest Request(GroupJourney j, ReceiptRecord receipt, string? expenseId = null, ReceiptReview? review = null,
        long version = 0, string? payerId = null) => new(expenseId ?? Guid.NewGuid().ToString(), "Dinner", (review ?? Review(j)).GrandTotalPaise,
        (review ?? Review(j)).Date, payerId ?? j.AliceId, SplitMode.Equal, [new(j.ThirdId)], version,
        new(receipt.Id, receipt.Version, review ?? Review(j), true));

    [Fact]
    public async Task ReceiptRevisionAndCanonicalSharesCommitOnceWithLedger()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var receipt = await Seed(factory, j);
        var input = Request(j, receipt); var key = Guid.NewGuid().ToString();
        var first = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input, key);
        var second = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input, key);
        Assert.Equal(first.GetRawText(), second.GetRawText());
        Assert.Equal("Exact", first.GetProperty("mode").GetString());
        Assert.Equal("Items", first.GetProperty("displaySplitKind").GetString());
        Assert.Equal(receipt.Id, first.GetProperty("receiptId").GetString());
        Assert.Equal(1, first.GetProperty("receiptRevision").GetInt64());
        var fetched = await ApiSession.Json(j.Bob.Client, HttpMethod.Get, $"{j.GroupPath}/expenses/{input.Id}");
        Assert.Equal(first.GetRawText(), fetched.GetRawText());
        var outsider = await ApiSession.Login(factory, "Outsider");
        await ApiSession.Error(outsider.Client, HttpMethod.Get, $"{j.GroupPath}/expenses/{input.Id}", HttpStatusCode.NotFound);
        var shares = first.GetProperty("shares"); Assert.Equal(101, shares.EnumerateObject().Sum(p => p.Value.GetInt64()));
        Assert.False(shares.TryGetProperty(j.ThirdId, out _));
        var revision = await factory.Services.GetRequiredService<ReceiptAttachmentService>().ReadRevisionAsync(receipt.Id, 1, default);
        Assert.Equal(ReceiptSplitEngine.Hash(input.Receipt!.Review), revision.ReviewHash);
        Assert.Equal(101, revision.Shares.Values.Sum());
        Assert.Equal(0, (await j.Nets()).Values.Sum());
        var stored = (await factory.Store.GetAsync($"RECEIPT#{receipt.Id}", "META"))!.Deserialize<ReceiptRecord>();
        Assert.Equal("attached", stored.State); Assert.Equal(input.Id, stored.ExpenseId);
        await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.NotFound,
            Request(j, stored));
        var page = await factory.Store.QueryAsync($"RECEIPT#{receipt.Id}", "REVISION#");
        Assert.Equal(2, page.Items.Count); // One immutable page and its manifest, never a replay copy.
    }

    [Fact]
    public async Task MissingConfirmationWrongPayerAndStaleReceiptProduceNoExpense()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var receipt = await Seed(factory, j);
        var input = Request(j, receipt);
        Assert.Equal("receipt_confirmation_required", (await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.UnprocessableEntity,
            input with { Receipt = input.Receipt! with { PayerConfirmed = false } })).GetProperty("code").GetString());
        Assert.Equal("receipt_payer_required", (await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.Forbidden,
            input with { PayerId = j.BobId })).GetProperty("code").GetString());
        Assert.Equal("receipt_version_conflict", (await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.Conflict,
            input with { Receipt = input.Receipt! with { Version = 0 } })).GetProperty("code").GetString());
        Assert.All((await j.Nets()).Values, amount => Assert.Equal(0, amount));
        Assert.Empty((await factory.Store.QueryAsync($"RECEIPT#{receipt.Id}", "REVISION#")).Items);
    }

    [Fact]
    public async Task DescriptionOnlyEditPreservesReceiptWhileOldClientResplitIsRejected()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var receipt = await Seed(factory, j);
        var input = Request(j, receipt);
        var saved = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input);
        var participants = saved.GetProperty("shares").EnumerateObject().Select(p => new SplitParticipant(p.Name, p.Value.GetInt64())).ToArray();
        var edit = input with { Receipt = null, Description = "Renamed", Version = 1, Mode = SplitMode.Exact, Participants = participants };
        var updated = await ApiSession.Json(j.Bob.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{input.Id}", edit);
        Assert.Equal(receipt.Id, updated.GetProperty("receiptId").GetString()); Assert.Equal(1, updated.GetProperty("receiptRevision").GetInt64());
        var before = await j.Nets();
        Assert.Equal("receipt_review_required", (await ApiSession.Error(j.Bob.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{input.Id}", HttpStatusCode.Conflict,
            edit with { Version = 2, AmountPaise = 103, Mode = SplitMode.Equal })).GetProperty("code").GetString());
        Assert.Equal(before, await j.Nets());
    }

    [Fact]
    public async Task ParticipantCanReviewEditAtomicallyAndPriorRevisionRemainsAvailable()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var receipt = await Seed(factory, j);
        var input = Request(j, receipt); await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input);
        var attached = (await factory.Store.GetAsync($"RECEIPT#{receipt.Id}", "META"))!.Deserialize<ReceiptRecord>();
        var edited = await ApiSession.Json(j.Bob.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{input.Id}", Request(j, attached, input.Id, Review(j, 300), 1));
        Assert.Equal(2, edited.GetProperty("receiptRevision").GetInt64());
        Assert.Equal(150, (await j.Nets())[j.AliceId]);
        var service = factory.Services.GetRequiredService<ReceiptAttachmentService>();
        Assert.Equal(101, (await service.ReadRevisionAsync(receipt.Id, 1, default)).Review.GrandTotalPaise);
        Assert.Equal(300, (await service.ReadRevisionAsync(receipt.Id, 2, default)).Review.GrandTotalPaise);
        Assert.Single((await factory.Store.QueryAsync($"GROUP#{j.GroupId}", "RECEIPT_DUP#")).Items);
    }

    [Fact]
    public async Task DeleteRestoreSchedulesAndCancelsPurgeAndNeverRestoresExplicitlyRemovedImages()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var receipt = await Seed(factory, j);
        var input = Request(j, receipt); await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input);
        var before = await j.Nets();
        await ApiSession.Json(j.Bob.Client, HttpMethod.Delete, $"{j.GroupPath}/expenses/{input.Id}", new { version = 1 });
        var job = (await factory.Store.GetAsync("WORK#receipt-purge", receipt.Id))!.Deserialize<ReceiptWork>();
        Assert.InRange(job.DueAt, DateTimeOffset.UtcNow.AddDays(29.99), DateTimeOffset.UtcNow.AddDays(30.01));
        await ApiSession.Json(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/expenses/{input.Id}/restore", new { version = 2 });
        Assert.Null(await factory.Store.GetAsync("WORK#receipt-purge", receipt.Id)); Assert.Equal(before, await j.Nets());
        var row = (await factory.Store.GetAsync($"RECEIPT#{receipt.Id}", "META"))!;
        var removed = row.Deserialize<ReceiptRecord>() with { ImagesRemoved = true, Version = row.Version + 1, PurgeAt = DateTimeOffset.UtcNow };
        await factory.Store.TransactAsync([StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, removed.Version, removed), row.Version),
            StoreMutation.Put(StoreRow.Create("WORK#receipt-purge", receipt.Id, 1, new ReceiptWork(receipt.Id, DateTimeOffset.UtcNow)), null)]);
        await ApiSession.Json(j.Bob.Client, HttpMethod.Delete, $"{j.GroupPath}/expenses/{input.Id}", new { version = 3 });
        await ApiSession.Json(j.Bob.Client, HttpMethod.Post, $"{j.GroupPath}/expenses/{input.Id}/restore", new { version = 4 });
        Assert.True((await factory.Store.GetAsync($"RECEIPT#{receipt.Id}", "META"))!.Deserialize<ReceiptRecord>().ImagesRemoved);
        Assert.NotNull(await factory.Store.GetAsync("WORK#receipt-purge", receipt.Id));
    }

    [Fact]
    public async Task ManualFallbackFencesActiveWorkerAndReleasesReservationOnlyOnce()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var receipt = await Seed(factory, j, "processing", true);
        var input = Request(j, receipt); var key = Guid.NewGuid().ToString();
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input, key);
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input, key);
        var attached = (await factory.Store.GetAsync($"RECEIPT#{receipt.Id}", "META"))!.Deserialize<ReceiptRecord>();
        Assert.False(attached.ReservationHeld); Assert.Null(attached.LeaseToken); Assert.Equal(receipt.Generation + 1, attached.Generation);
        var quota = (await factory.Store.GetAsync($"USER#{j.Alice.UserId}", $"SCAN_QUOTA#{receipt.QuotaMonth}"))!.Deserialize<ReceiptQuota>();
        Assert.Equal(0, quota.Reserved); Assert.Equal(0, quota.Used);
    }

    [Fact]
    public async Task EditingAccountingAfterImageRemovalCannotCancelPhysicalPurge()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var receipt = await Seed(factory, j);
        var input = Request(j, receipt); await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input);
        var attached = (await factory.Store.GetAsync($"RECEIPT#{receipt.Id}", "META"))!.Deserialize<ReceiptRecord>();
        await ApiSession.Json(j.Bob.Client, HttpMethod.Delete, $"/v1/receipts/{receipt.Id}/images", new { version = attached.Version });
        var removed = (await factory.Store.GetAsync($"RECEIPT#{receipt.Id}", "META"))!.Deserialize<ReceiptRecord>();
        var purgeBefore = (await factory.Store.GetAsync("WORK#receipt-purge", receipt.Id))!;
        await ApiSession.Json(j.Alice.Client, HttpMethod.Put, $"{j.GroupPath}/expenses/{input.Id}", Request(j, removed, input.Id, Review(j, 201), 1));
        var after = (await factory.Store.GetAsync($"RECEIPT#{receipt.Id}", "META"))!.Deserialize<ReceiptRecord>();
        Assert.True(after.ImagesRemoved); Assert.Equal(removed.PurgeAt, after.PurgeAt);
        var purgeAfter = (await factory.Store.GetAsync("WORK#receipt-purge", receipt.Id))!;
        Assert.Equal(purgeBefore.Version, purgeAfter.Version); Assert.Equal(purgeBefore.Data.GetRawText(), purgeAfter.Data.GetRawText());
    }

    [Fact]
    public async Task LostMembershipRejectsReceiptSaveReplayDespiteRetainedLedgerAccess()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var receipt = await Seed(factory, j);
        var input = Request(j, receipt); var key = Guid.NewGuid().ToString();
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", input, key);
        await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/leave", new { acknowledgeBalance = true });
        await ApiSession.Error(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", HttpStatusCode.NotFound, input, key);
    }

    [Fact]
    public async Task FullCartesianRevisionAndFiftyBalancesFitOneAtomicTransaction()
    {
        await using var factory = new ApiFactory(); var j = await GroupJourney.Create(factory); var store = factory.Store;
        var groupRow = (await store.GetAsync($"GROUP#{j.GroupId}", "META"))!; var group = groupRow.Deserialize<Group>();
        var added = Enumerable.Range(0, 47).Select(i => new Member(Guid.NewGuid().ToString(), null, $"Person {i}", true)).ToArray();
        var all = group.Members.Concat(added).ToArray(); var writes = new List<StoreMutation>
        { StoreMutation.Put(StoreRow.Create(groupRow.Pk, groupRow.Sk, groupRow.Version + 1, group with { Members = all, Version = group.Version + 1 }), groupRow.Version) };
        writes.AddRange(added.Select(m => StoreMutation.Put(StoreRow.Create(groupRow.Pk, $"BALANCE#{m.Id}", 1, new Balance(m.Id, 0, new Dictionary<string, long>())), null)));
        await store.TransactAsync(writes);
        var receipt = await Seed(factory, j); var name = string.Concat(Enumerable.Repeat("🧾", 200)); var ids = all.Select(m => m.Id).ToArray();
        var review = new ReceiptReview(name, new DateOnly(2026, 9, 26), "INR", 150000,
            Enumerable.Range(0, 150).Select(i => new ReceiptItem(Guid.NewGuid().ToString(), name, "1", 1000, 1000, ids, Transliteration: name)).ToArray(),
            Enumerable.Range(0, 20).Select(i => new ReceiptCharge(Guid.NewGuid().ToString(), "Tax", "Tax", 0, Weights: ids.ToDictionary(id => id, _ => 1L))).ToArray(), true);
        var saved = await ApiSession.Json(j.Alice.Client, HttpMethod.Post, $"{j.GroupPath}/expenses", Request(j, receipt, review: review));
        Assert.Equal(50, saved.GetProperty("shares").EnumerateObject().Count());
        var pages = (await store.QueryAsync($"RECEIPT#{receipt.Id}", "REVISION#")).Items;
        Assert.True(pages.Count > 12); Assert.True(pages.Count <= 25);
        Assert.All(pages, page => Assert.True(System.Text.Encoding.UTF8.GetByteCount(page.Data.GetRawText()) < 400 * 1024));
        Assert.Equal(0, (await j.Nets()).Values.Sum());
    }
}
