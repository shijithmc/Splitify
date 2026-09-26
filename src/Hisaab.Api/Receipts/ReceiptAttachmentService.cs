using System.Security.Cryptography;
using System.Text.Encodings.Web;
using System.Text.Json;
using Hisaab.Api.Contracts;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
using Hisaab.Domain.Receipts;

namespace Hisaab.Api.Receipts;

public sealed class ReceiptAttachmentService(IAtomicStore store, ReceiptQuotaService quotas, IConfiguration configuration)
{
    private const int PageBytes = 64 * 1024;
    private static readonly JsonSerializerOptions RevisionJson = new(JsonDefaults.Options) { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public async Task AuthorizeAsync(string receiptId, string groupId, string userId, CancellationToken ct)
    {
        var group = (await store.GetAsync($"GROUP#{groupId}", "META", ct))?.Deserialize<Group>();
        var receipt = (await store.GetAsync($"RECEIPT#{receiptId}", "META", ct))?.Deserialize<ReceiptRecord>();
        if (group is null || group.Deleted || !group.Members.Any(m => m.UserId == userId && !m.HasLeft && !m.IsDeleted) ||
            receipt is null || receipt.GroupId != groupId || receipt.ExpenseId is null && receipt.UploaderId != userId)
            throw Missing();
    }

    public async Task<ReceiptAttachment> BuildAsync(Group group, Expense draft, Expense? current,
        ReceiptConfirmationRequest? confirmation, string actorUserId, DateTimeOffset now, CancellationToken ct)
    {
        if (confirmation is null)
        {
            if (current?.ReceiptId is null) return new(draft, []);
            // An old client may edit descriptions, but cannot silently make stored evidence disagree with money.
            var split = SplitEngine.Calculate(draft.AmountPaise, draft.Mode, draft.Participants);
            if (draft.AmountPaise != current.AmountPaise || draft.PayerId != current.PayerId || draft.Date != current.Date ||
                split.Shares.Count != current.Shares.Count || split.Shares.Any(p => current.Shares.GetValueOrDefault(p.Key, -1) != p.Value))
                throw new DomainException(409, "receipt_review_required", "Review the attached receipt before changing its date, payer or split.");
            return new(draft with { ReceiptId = current.ReceiptId, ReceiptRevision = current.ReceiptRevision, DisplaySplitKind = current.DisplaySplitKind }, []);
        }
        if (!Guid.TryParse(confirmation.ReceiptId, out _) || !confirmation.PayerConfirmed)
            throw new DomainException(422, "receipt_confirmation_required", "Confirm the reviewed receipt and payer before saving.");
        var row = await store.GetAsync($"RECEIPT#{confirmation.ReceiptId}", "META", ct) ?? throw Missing();
        var receipt = row.Deserialize<ReceiptRecord>();
        if (receipt.GroupId != group.Id || current?.ReceiptId is not null && current.ReceiptId != receipt.Id ||
            receipt.ExpenseId is not null && receipt.ExpenseId != draft.Id ||
            receipt.ExpenseId is null && receipt.UploaderId != actorUserId) throw Missing();
        if (receipt.Version != confirmation.Version || row.Version != receipt.Version)
            throw new DomainException(409, "receipt_version_conflict", "This receipt changed. Review its latest version.");
        if (receipt.ExpenseId is null && group.Members.SingleOrDefault(m => m.Id == draft.PayerId)?.UserId != actorUserId)
            throw new DomainException(403, "receipt_payer_required", "The signed-in payer must confirm a new receipt expense.");
        if (receipt.State is not ("ready" or "manual_ready" or "failed" or "unreadable" or "queued" or "processing" or "attached") ||
            receipt.ExpenseId is null && (receipt.Media.Count == 0 || receipt.ImagesRemoved || receipt.ExpiresAt <= now))
            throw new DomainException(409, "receipt_not_ready", "Upload a readable receipt before attaching it.");
        var preview = ReceiptSplitEngine.Calculate(confirmation.Review,
            group.Members.Where(m => !m.HasLeft && !m.IsDeleted).Select(m => m.Id).ToArray());
        if (draft.AmountPaise != confirmation.Review.GrandTotalPaise || draft.Date != confirmation.Review.Date)
            throw new DomainException(422, "receipt_total_mismatch", "The expense date and INR total must match the confirmed receipt.");
        if (confirmation.Review.SplitByItems)
            draft = draft with { Mode = SplitMode.Exact, Participants = preview.Shares.Select(p => new SplitParticipant(p.Key, p.Value)).ToArray(), Shares = preview.Shares };
        else draft = draft with { Shares = SplitEngine.Calculate(draft.AmountPaise, draft.Mode, draft.Participants).Shares };

        var revision = checked(receipt.Revision + 1);
        var document = new ReceiptRevision(receipt.Id, revision, confirmation.Review, draft.Shares, preview.ReviewHash, now);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(document, RevisionJson);
        if (bytes.Length > ReceiptSplitEngine.MaximumRevisionBytes)
            throw new DomainException(422, "receipt_too_large", "This reviewed receipt exceeds the supported size.");
        var writes = (await quotas.ReleaseAsync(receipt, false, ct)).ToList();
        writes.AddRange(await new ReceiptUploadAdmission(store, configuration).ReleaseAsync(receipt, ct));
        var pageCount = (bytes.Length + PageBytes - 1) / PageBytes;
        for (var page = 0; page < pageCount; page++)
        {
            var payload = Convert.ToBase64String(bytes, page * PageBytes, Math.Min(PageBytes, bytes.Length - page * PageBytes));
            writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk, RevisionKey(revision, page), 1, new ReceiptRevisionPage(payload)), null));
        }
        writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk, RevisionKey(revision), 1,
            new ReceiptRevisionManifest(revision, pageCount, bytes.Length, Convert.ToHexString(SHA256.HashData(bytes)))), null));
        var attached = receipt with
        {
            State = "attached", ExpenseId = draft.Id, Revision = revision, RevisionHash = preview.ReviewHash,
            Version = row.Version + 1, Generation = receipt.ReservationHeld ? receipt.Generation + 1 : receipt.Generation, LeaseToken = null,
            LeaseUntil = null, ReservationHeld = false, PurgeAt = receipt.ImagesRemoved ? receipt.PurgeAt : null
        };
        writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, attached.Version, attached), row.Version));
        var groupIndex = await store.GetAsync($"GROUP#{group.Id}", $"RECEIPT#{receipt.Id}", ct);
        writes.Add(StoreMutation.Put(StoreRow.Create($"GROUP#{group.Id}", $"RECEIPT#{receipt.Id}", (groupIndex?.Version ?? 0) + 1,
            new { receiptId = receipt.Id, expenseId = draft.Id }), groupIndex?.Version));
        var duplicateKey = ReceiptFingerprint.Prefix(confirmation.Review, configuration) + draft.Id;
        if (receipt.Revision > 0)
        {
            var previous = await ReadRevisionAsync(receipt.Id, receipt.Revision, ct);
            var previousKey = ReceiptFingerprint.Prefix(previous.Review, configuration) + draft.Id;
            if (previousKey != duplicateKey)
            {
                var old = await store.GetAsync($"GROUP#{group.Id}", previousKey, ct);
                if (old is not null) writes.Add(StoreMutation.Delete(old.Pk, old.Sk, old.Version));
            }
        }
        var duplicate = await store.GetAsync($"GROUP#{group.Id}", duplicateKey, ct);
        writes.Add(StoreMutation.Put(StoreRow.Create($"GROUP#{group.Id}", duplicateKey, (duplicate?.Version ?? 0) + 1,
            new ReceiptDuplicate(draft.Id, receipt.Id, duplicate?.Deserialize<ReceiptDuplicate>().CreatedAt ?? now,
                duplicate?.Deserialize<ReceiptDuplicate>().AddedBy ?? group.Members.Single(m => m.UserId == actorUserId).Id)), duplicate?.Version));
        // Leave worker wakeups harmless: the generation/state fence prevents stale inference from writing.
        var purge = await store.GetAsync("WORK#receipt-purge", receipt.Id, ct);
        if (purge is not null && !receipt.ImagesRemoved) writes.Add(StoreMutation.Delete(purge.Pk, purge.Sk, purge.Version));
        return new(draft with { ReceiptId = receipt.Id, ReceiptRevision = revision, DisplaySplitKind = confirmation.Review.SplitByItems ? "Items" : "Total" }, writes);
    }

    public async Task<IReadOnlyList<StoreMutation>> ExpenseTransitionAsync(Expense saved, bool restore, DateTimeOffset now, CancellationToken ct)
    {
        if (saved.ReceiptId is null) return [];
        var row = await store.GetAsync($"RECEIPT#{saved.ReceiptId}", "META", ct) ?? throw Missing();
        var receipt = row.Deserialize<ReceiptRecord>();
        if (receipt.GroupId != saved.GroupId || receipt.ExpenseId != saved.Id) throw Missing();
        var due = restore ? (DateTimeOffset?)null : saved.DeletedAt!.Value.AddDays(30);
        var next = receipt with { Version = row.Version + 1, PurgeAt = receipt.ImagesRemoved ? receipt.PurgeAt : due };
        var writes = new List<StoreMutation> { StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, next.Version, next), row.Version) };
        var purge = await store.GetAsync("WORK#receipt-purge", receipt.Id, ct);
        if (!receipt.ImagesRemoved)
        {
            if (restore && purge is not null) writes.Add(StoreMutation.Delete(purge.Pk, purge.Sk, purge.Version));
            if (!restore) writes.Add(StoreMutation.Put(StoreRow.Create("WORK#receipt-purge", receipt.Id, (purge?.Version ?? 0) + 1,
                new ReceiptWork(receipt.Id, due!.Value)), purge?.Version));
        }
        _ = now;
        return writes;
    }

    public async Task<IReadOnlyList<StoreMutation>> GroupDeletedAsync(string groupId, DateTimeOffset now, CancellationToken ct)
    {
        var row = await store.GetAsync("WORK#receipt-group-purge", groupId, ct);
        return [StoreMutation.Put(StoreRow.Create("WORK#receipt-group-purge", groupId, (row?.Version ?? 0) + 1,
            new ReceiptWork(groupId, now.AddDays(30))), row?.Version)];
    }

    // Authorization belongs to the caller, including for historical revision reads.
    public async Task<ReceiptRevision> ReadRevisionAsync(string receiptId, long revision, CancellationToken ct)
    {
        var pk = $"RECEIPT#{receiptId}";
        var row = await store.GetAsync(pk, RevisionKey(revision), ct) ?? throw Missing();
        var manifest = row.Deserialize<ReceiptRevisionManifest>();
        if (manifest.Pages is < 1 or > 24 || manifest.Bytes is < 1 or > ReceiptSplitEngine.MaximumRevisionBytes)
            throw new InvalidOperationException("Invalid receipt revision manifest.");
        using var buffer = new MemoryStream();
        for (var page = 0; page < manifest.Pages; page++)
        {
            var part = await store.GetAsync(pk, RevisionKey(revision, page), ct) ?? throw new InvalidOperationException("Missing receipt revision page.");
            var decoded = Convert.FromBase64String(part.Deserialize<ReceiptRevisionPage>().Payload);
            if (decoded.Length > PageBytes) throw new InvalidOperationException("Invalid receipt revision page.");
            buffer.Write(decoded);
        }
        var bytes = buffer.ToArray();
        if (bytes.Length != manifest.Bytes || Convert.ToHexString(SHA256.HashData(bytes)) != manifest.ContentHash)
            throw new InvalidOperationException("Receipt revision failed integrity verification.");
        return JsonSerializer.Deserialize<ReceiptRevision>(bytes, JsonDefaults.Options) ?? throw new InvalidOperationException("Invalid receipt revision.");
    }

    private static string RevisionKey(long revision, int? page = null) => $"REVISION#{revision:D10}" + (page is null ? "#MANIFEST" : $"#PAGE#{page:D2}");
    private static DomainException Missing() => new(404, "receipt_not_found", "Receipt not found.");
}
