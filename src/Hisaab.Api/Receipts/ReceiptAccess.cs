using Hisaab.Api.Identity;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptAccess(IAtomicStore store)
{
    public async Task EnsureSessionAsync(Actor actor, CancellationToken ct)
    {
        var profile = await store.GetAsync($"USER#{actor.User.Id}", "PROFILE", ct);
        var session = await store.GetAsync($"SESSION#{actor.SessionHash}", "META", ct);
        if (profile?.Deserialize<UserAccount>().Status != "active" || session?.Deserialize<SessionRecord>().AccessExpiresAt <= DateTimeOffset.UtcNow || session is null)
            throw new DomainException(401, "session_expired", "Sign in again.");
    }
    public async Task<StoreRow> GroupAsync(string groupId, string userId, CancellationToken ct)
    {
        var row = await store.GetAsync($"GROUP#{groupId}", "META", ct);
        var group = row?.Deserialize<Group>();
        if (group is null || group.Deleted || !group.Members.Any(m => m.UserId == userId && !m.HasLeft && !m.IsDeleted)) throw Missing();
        return row!;
    }
    public async Task<StoreRow> ReceiptAsync(Actor actor, string id, bool ownerOnly, CancellationToken ct)
    {
        await EnsureSessionAsync(actor, ct);
        var row = await store.GetAsync($"RECEIPT#{id}", "META", ct) ?? throw Missing();
        var receipt = row.Deserialize<ReceiptRecord>();
        await GroupAsync(receipt.GroupId, actor.User.Id, ct);
        if ((ownerOnly || receipt.ExpenseId is null) && receipt.UploaderId != actor.User.Id) throw Missing();
        if (receipt.State is "cancelled" or "expired" || receipt.ExpenseId is null && receipt.ExpiresAt <= DateTimeOffset.UtcNow) throw Missing();
        return row;
    }
    public static DomainException Missing() => new(404, "not_found", "Receipt not found.");
    public static void Version(ReceiptRecord receipt, long expected)
    {
        if (receipt.Version != expected) throw new DomainException(409, "receipt_version_conflict", "This receipt changed. Review the latest version.");
    }
}
