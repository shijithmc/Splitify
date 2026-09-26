using Hisaab.Api.Contracts;
using Hisaab.Api.Identity;
using Hisaab.Api.Receipts;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Ledger;

public sealed class LedgerApplication(IAtomicStore store, CommandExecutor commands, IConfiguration config, IdentityService identity, TokenProtector protector, ReceiptAttachmentService receipts)
{
    public async Task<GroupDetail> GetGroupAsync(string id, string userId, CancellationToken ct = default)
    {
        var (row, group, balances, _) = await SnapshotAsync(id, userId, ct); _ = row;
        return await DetailAsync(group, balances, ct);
    }
    public async Task<object> ListGroupsAsync(string userId, CancellationToken ct = default)
    {
        var items = new List<GroupSummary>();
        foreach (var edge in await AllAsync($"USER#{userId}", "GROUP#", ct))
        {
            var row = await store.GetAsync($"GROUP#{edge.Sk[6..]}", "META", ct); if (row is null) continue;
            var group = row.Deserialize<Group>(); if (group.Deleted || !group.Members.Any(m => m.UserId == userId)) continue;
            IReadOnlyList<Balance> balances;
            try { var snapshot = await SnapshotAsync(group.Id, userId, ct); group = snapshot.Item2; balances = snapshot.Item3; } catch (DomainException ex) when (ex.Status == 404) { continue; }
            var own = group.Members.Where(m => m.UserId == userId).Select(m => m.Id).ToHashSet(StringComparer.Ordinal);
            items.Add(new(group.Id, group.Name, group.Type, group.Archived, group.Version, group.Members.Count, balances.Where(b => own.Contains(b.ParticipantId)).Sum(b => b.NetPaise)));
        }
        return new { items };
    }
    public Task<System.Text.Json.JsonElement> CreateGroupAsync(Actor actor, string key, CreateGroupRequest input, CancellationToken ct = default)
    {
        var id = Ids.New(); var pid = Ids.New();
        return commands.ExecuteAsync(actor, key, "groups:create", input, () =>
        {
            if (!Enum.IsDefined(input.Type)) throw new DomainException(422, "type_invalid", "Choose a valid group type.");
            var member = new Member(pid, actor.User.Id, actor.User.DisplayName);
            var group = new Group(id, GroupRules.ValidateName(input.Name), input.Type, false, 1, actor.User.Id, [member]);
            var balance = new Balance(pid, 0, new Dictionary<string, long>());
            var writes = new List<StoreMutation> { StoreMutation.Put(StoreRow.Create($"GROUP#{id}", "META", 1, group), null), StoreMutation.Put(StoreRow.Create($"GROUP#{id}", $"BALANCE#{pid}", 1, balance), null), StoreMutation.Put(StoreRow.Create($"USER#{actor.User.Id}", $"GROUP#{id}", 1, new { groupId = id }), null), StoreMutation.Put(StoreRow.Create("GROUPS", id, 1, new { groupId = id }), null) };
            AddEvent(writes, group, actor.User.Id, "group_created", id);
            return Task.FromResult(new MutationResult(new GroupDetail(id, group.Name, group.Type, false, 1, actor.User.Id, [MemberDetail.From(member, DateTimeOffset.UtcNow)], [balance]), writes));
        }, ct);
    }
    public Task<System.Text.Json.JsonElement> EditGroupAsync(Actor actor, string key, string id, EditGroupRequest input, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, $"group:{id}:edit", input, async () =>
    {
        var (row, group, balances, _) = await SnapshotAsync(id, actor.User.Id, ct);
        RequireVersion(group.Version, input.Version); GroupRules.RequireActiveMember(group, actor.User.Id);
        var updated = group with { Name = input.Name is null ? group.Name : GroupRules.ValidateName(input.Name), Archived = input.Archived ?? group.Archived, Version = group.Version + 1 };
        var writes = new List<StoreMutation> { PutGroup(row, updated) }; AddEvent(writes, updated, actor.User.Id, "group_updated", id);
        return new(await DetailAsync(updated, balances, ct), writes);
    }, ct);
    public Task<System.Text.Json.JsonElement> AddMemberAsync(Actor actor, string key, string id, MemberRequest input, CancellationToken ct = default)
    {
        var pid = Ids.New();
        return commands.ExecuteAsync(actor, key, $"group:{id}:member", input, async () =>
        {
            var (row, group, _, _) = await SnapshotAsync(id, actor.User.Id, ct); GroupRules.RequireActiveMember(group, actor.User.Id); GroupRules.EnsureCanAddMember(group);
            if (!string.IsNullOrWhiteSpace(input.Email) && (!input.Email.Contains('@') || input.Email.Length > 254)) throw new DomainException(422, "email_invalid", "Enter a valid email address.");
            if (!string.IsNullOrWhiteSpace(input.Phone) && input.Phone.Length > 25) throw new DomainException(422, "phone_invalid", "Enter a valid phone number.");
            var member = new Member(pid, null, IdentityService.Name(input.DisplayName), true, CreatedAt: DateTimeOffset.UtcNow);
            var updated = group with { Members = group.Members.Append(member).ToArray(), Version = group.Version + 1 };
            var writes = new List<StoreMutation> { PutGroup(row, updated), StoreMutation.Put(StoreRow.Create(row.Pk, $"BALANCE#{pid}", 1, new Balance(pid, 0, new Dictionary<string, long>())), null) };
            // Contact data is encrypted separately and expires with the invitation; never part of balances.
            if (!string.IsNullOrWhiteSpace(input.Email) || !string.IsNullOrWhiteSpace(input.Phone))
            {
                var contact = new { email = input.Email?.Trim(), phone = input.Phone?.Trim() }; var until = DateTimeOffset.UtcNow.AddDays(7);
                writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk, $"CONTACT#{pid}", 1, new { encrypted = protector.Protect(System.Text.Json.JsonSerializer.Serialize(contact, JsonDefaults.Options)) }, until.ToUnixTimeSeconds()), null));
                if (!string.IsNullOrWhiteSpace(input.Email))
                {
                    var token = Ids.Token();
                    writes.Add(StoreMutation.Put(StoreRow.Create($"INVITE#{Ids.Hash(token)}", "META", 1, new InviteRecord(id, pid, until, actor.User.Id), until.ToUnixTimeSeconds()), null));
                    writes.Add(StoreMutation.Put(StoreRow.Create(identity.ContactKey(input.Email), $"INVITE#{id}#{pid}", 1, new { groupId = id, participantId = pid, encryptedToken = protector.Protect(token), expiresAt = until }, until.ToUnixTimeSeconds()), null));
                }
            }
            AddEvent(writes, updated, actor.User.Id, "member_added", pid);
            return new(member, writes);
        }, ct);
    }
    public Task<System.Text.Json.JsonElement> MarkExternalAsync(Actor actor, string key, string id, string participantId, MarkExternalRequest input, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, $"group:{id}:external:{participantId}", input, async () =>
    {
        var (row, group, balances, _) = await SnapshotAsync(id, actor.User.Id, ct);
        GroupRules.RequireActiveMember(group, actor.User.Id); GroupRules.EnsureWritable(group);
        if (group.CreatorId != actor.User.Id) throw new DomainException(403, "creator_required", "Only the group creator can mark a participant external.");
        GroupRules.RequireVersion(group.Version, input.Version);
        var member = group.Members.FirstOrDefault(m => m.Id == participantId) ?? throw NotFound();
        if (!MemberDetail.From(member, DateTimeOffset.UtcNow).ExternalReviewDue)
            throw new DomainException(409, "external_review_not_due", "Only an unclaimed placeholder retained for at least 90 days can be marked external.");
        var external = member with { IsPlaceholder = false, IsExternal = true };
        var updated = group with { Version = group.Version + 1, Members = group.Members.Select(m => m.Id == participantId ? external : m).ToArray() };
        var writes = new List<StoreMutation> { PutGroup(row, updated) };
        AddEvent(writes, updated, actor.User.Id, "member_marked_external", participantId);
        return new(await DetailAsync(updated, balances, ct), writes);
    }, ct);
    public Task<System.Text.Json.JsonElement> RevokeInviteAsync(Actor actor, string key, string id, RevokeInviteRequest input, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, $"group:{id}:invite:revoke", input, async () =>
    {
        var (row, group, _, _) = await SnapshotAsync(id, actor.User.Id, ct);
        GroupRules.RequireActiveMember(group, actor.User.Id); GroupRules.EnsureWritable(group);
        if (group.CreatorId != actor.User.Id) throw new DomainException(403, "creator_required", "Only the group creator can revoke an invitation.");
        if (string.IsNullOrWhiteSpace(input.Token) || input.Token.Length != 64) throw NotFound();
        var invitation = await store.GetAsync($"INVITE#{Ids.Hash(input.Token)}", "META", ct);
        if (invitation is null || invitation.Deserialize<InviteRecord>().GroupId != id) throw NotFound();
        var invite = invitation.Deserialize<InviteRecord>();
        if (invite.RevokedAt is not null)
            return new(new { revoked = true }, [StoreMutation.Condition(row.Pk, row.Sk, row.Version)]);
        var updated = group with { Version = group.Version + 1 };
        var writes = new List<StoreMutation>{PutGroup(row,updated),StoreMutation.Put(StoreRow.Create(invitation.Pk,invitation.Sk,invitation.Version+1,
            invite with{RevokedAt=DateTimeOffset.UtcNow},invitation.ExpiresAtUnixSeconds),invitation.Version)};
        AddEvent(writes, updated, actor.User.Id, "invite_revoked", Ids.Hash(input.Token));
        return new(new { revoked = true }, writes);
    }, ct);
    public Task<System.Text.Json.JsonElement> CreateInviteAsync(Actor actor, string key, string id, InviteRequest input, CancellationToken ct = default)
    {
        var token = Ids.Token();
        return commands.ExecuteAsync(actor, key, $"group:{id}:invite", input, async () =>
        {
            var (row, group, _, _) = await SnapshotAsync(id, actor.User.Id, ct); GroupRules.RequireActiveMember(group, actor.User.Id); GroupRules.EnsureWritable(group);
            if (input.ParticipantId is not null && !group.Members.Any(m => m.Id == input.ParticipantId && m.UserId is null && !m.IsDeleted)) throw new DomainException(422, "placeholder_invalid", "Choose an unclaimed placeholder.");
            var until = DateTimeOffset.UtcNow.AddDays(7); var baseUrl = config["Hisaab:InviteBaseUrl"];
            var url = string.IsNullOrWhiteSpace(baseUrl) ? $"hisaab://invite/{token}" : $"{baseUrl.TrimEnd('/')}/{token}";
            return new(new { token, url, expiresAt = until }, new[] { StoreMutation.Condition(row.Pk, row.Sk, row.Version), StoreMutation.Put(StoreRow.Create($"INVITE#{Ids.Hash(token)}", "META", 1, new InviteRecord(id, input.ParticipantId, until, actor.User.Id), until.ToUnixTimeSeconds()), null) });
        }, ct);
    }
    public Task<System.Text.Json.JsonElement> AcceptInviteAsync(Actor actor, string key, AcceptInviteRequest input, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, "invite:accept", input, async () =>
    {
        if (string.IsNullOrWhiteSpace(input.Token) || input.Token.Length != 64) throw new DomainException(404, "invite_invalid", "This invitation is unavailable.");
        var invitation = await store.GetAsync($"INVITE#{Ids.Hash(input.Token)}", "META", ct);
        if (invitation is null || invitation.Deserialize<InviteRecord>().ExpiresAt <= DateTimeOffset.UtcNow || invitation.Deserialize<InviteRecord>().RevokedAt is not null) throw new DomainException(404, "invite_expired", "This invitation has expired or was already used.");
        var invite = invitation.Deserialize<InviteRecord>(); var row = await store.GetAsync($"GROUP#{invite.GroupId}", "META", ct) ?? throw NotFound(); var group = row.Deserialize<Group>(); GroupRules.EnsureWritable(group);
        var existing = group.Members.FirstOrDefault(m => m.UserId == actor.User.Id);
        if (existing is not null) throw new DomainException(409, "already_member", "You already belong to this group.");
        Member member;
        if (invite.ParticipantId is not null)
        {
            var placeholder = group.Members.FirstOrDefault(m => m.Id == invite.ParticipantId && m.UserId is null && !m.IsDeleted) ?? throw new DomainException(409, "already_claimed", "This member has already been claimed.");
            member = placeholder with { UserId = actor.User.Id, DisplayName = actor.User.DisplayName, IsPlaceholder = false, IsExternal = false };
            group = group with { Members = group.Members.Select(m => m.Id == member.Id ? member : m).ToArray(), Version = group.Version + 1 };
        }
        else { GroupRules.EnsureCanAddMember(group); member = new(Ids.New(), actor.User.Id, actor.User.DisplayName); group = group with { Members = group.Members.Append(member).ToArray(), Version = group.Version + 1 }; }
        var writes = new List<StoreMutation> { PutGroup(row, group), StoreMutation.Delete(invitation.Pk, invitation.Sk, invitation.Version), StoreMutation.Put(StoreRow.Create($"USER#{actor.User.Id}", $"GROUP#{group.Id}", 1, new { groupId = group.Id }), null) };
        if (invite.ParticipantId is null) writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk, $"BALANCE#{member.Id}", 1, new Balance(member.Id, 0, new Dictionary<string, long>())), null));
        AddEvent(writes, group, actor.User.Id, "invite_accepted", member.Id);
        var balances = (await store.QueryAsync(row.Pk, "BALANCE#", 100, ct: ct)).Items.Select(b => b.Deserialize<Balance>()).ToList(); if (invite.ParticipantId is null) balances.Add(new(member.Id, 0, new Dictionary<string, long>()));
        return new(await DetailAsync(group, balances, ct), writes);
    }, ct);
    public async Task<object> ContactInvitesAsync(Actor actor, CancellationToken ct = default)
    {
        var items = new List<object>();
        var sessionRow = await store.GetAsync($"SESSION#{actor.SessionHash}", "META", ct); var session = sessionRow?.Deserialize<SessionRecord>();
        if (session?.VerifiedInviteEmail is null || session.CreatedAt < DateTimeOffset.UtcNow.AddMinutes(-10)) return new { items };
        var pk = identity.ContactKey(session.VerifiedInviteEmail);
        foreach (var row in await AllAsync(pk, "INVITE#", ct))
        {
            var until = row.Data.GetProperty("expiresAt").GetDateTimeOffset(); if (until <= DateTimeOffset.UtcNow) continue;
            var gid = row.Data.GetProperty("groupId").GetString()!; var pid = row.Data.GetProperty("participantId").GetString()!;
            var meta = await store.GetAsync($"GROUP#{gid}", "META", ct); if (meta is null) continue; var group = meta.Deserialize<Group>();
            if (group.Deleted || group.Archived || !group.Members.Any(m => m.Id == pid && m.IsPlaceholder && m.UserId is null)) continue;
            var token = protector.Unprotect(row.Data.GetProperty("encryptedToken").GetString()!);
            var invitation = await store.GetAsync($"INVITE#{Ids.Hash(token)}", "META", ct);
            if (invitation is null || invitation.Deserialize<InviteRecord>().RevokedAt is not null) continue;
            items.Add(new { groupId = gid, participantId = pid, groupName = group.Name, token, expiresAt = until });
        }
        return new { items };
    }
    public async Task<object> ExpensesAsync(string id, string userId, string? cursor, CancellationToken ct = default)
    {
        await RequireGroupAsync(id, userId, ct);
        StorePage page;
        try { page = await store.QueryAsync($"GROUP#{id}", "EXPENSEDATE#", 25, cursor, ct); } catch (StoreValidationException) { throw new DomainException(400, "cursor_invalid", "This page cursor is invalid for the group."); }
        var items = new List<Expense>();
        foreach (var pointer in page.Items) { var row = await store.GetAsync(pointer.Pk, $"EXPENSE#{pointer.Data.GetProperty("id").GetString()}", ct); if (row is not null) items.Add(row.Deserialize<Expense>()); }
        return new { items, nextCursor = page.NextCursor };
    }
    public async Task<Expense> ExpenseAsync(string id, string expenseId, string userId, CancellationToken ct = default)
    {
        await RequireGroupAsync(id, userId, ct);
        var expense = (await store.GetAsync($"GROUP#{id}", $"EXPENSE#{expenseId}", ct))?.Deserialize<Expense>() ?? throw NotFound();
        await RequireGroupAsync(id, userId, ct);
        return expense;
    }
    public async Task<System.Text.Json.JsonElement> SaveExpenseAsync(Actor actor, string key, string id, ExpenseRequest input, bool edit, CancellationToken ct = default)
    {
        // Replays must still check current receipt membership before returning a cached result.
        if (input.Receipt is not null) await receipts.AuthorizeAsync(input.Receipt.ReceiptId, id, actor.User.Id, ct);
        return await commands.ExecuteAsync(actor, key, $"group:{id}:expense:{input.Id}:{edit}", input, async () =>
    {
        if (!Guid.TryParse(input.Id, out _)) throw new DomainException(422, "id_invalid", "Expense ID must be a UUID.");
        var (row, group, balances, balanceRows) = await SnapshotAsync(id, actor.User.Id, ct);
        var currentRow = await store.GetAsync(row.Pk, $"EXPENSE#{input.Id}", ct); var current = currentRow?.Deserialize<Expense>();
        var now = DateTimeOffset.UtcNow;
        var draft = new Expense(input.Id, id, input.Description, input.AmountPaise, input.Date, input.PayerId, input.Mode, input.Participants, new Dictionary<string, long>(), 0, null, actor.User.Id, now);
        var attachment = await receipts.BuildAsync(group, draft, current, input.Receipt, actor.User.Id, now, ct);
        draft = attachment.Draft;
        Expense saved;
        if (edit) { if (current is null) throw NotFound(); saved = ExpenseService.Update(group, current, draft, actor.User.Id, input.Version, now); balances = LedgerEngine.ApplyExpense(balances, current, -1); }
        else { if (current is not null) throw new DomainException(409, "expense_exists", "This expense has already been saved."); saved = ExpenseService.Create(group, draft, actor.User.Id, now); }
        balances = LedgerEngine.ApplyExpense(balances, saved);
        var updated = group with { Version = group.Version + 1, ExpenseCount = group.ExpenseCount + (edit ? 0 : 1) };
        var writes = new List<StoreMutation> { PutGroup(row, updated), StoreMutation.Put(StoreRow.Create(row.Pk, $"EXPENSE#{saved.Id}", saved.Version, saved), currentRow?.Version) };
        writes.AddRange(attachment.Writes);
        if (current is not null && current.Date != saved.Date) { var old = await store.GetAsync(row.Pk, DateKey(current), ct); if (old is not null) writes.Add(StoreMutation.Delete(old.Pk, old.Sk, old.Version)); }
        var pointer = await store.GetAsync(row.Pk, DateKey(saved), ct); writes.Add(StoreMutation.Put(StoreRow.Create(row.Pk, DateKey(saved), (pointer?.Version ?? 0) + 1, new { id = saved.Id }), pointer?.Version));
        AddBalances(writes, row.Pk, balances, balanceRows); AddEvent(writes, updated, actor.User.Id, edit ? "expense_updated" : "expense_added", saved.Id, saved.Participants.Select(p => p.ParticipantId).Append(saved.PayerId).Concat(current?.Participants.Select(p => p.ParticipantId) ?? []).Concat(current is null ? [] : [current.PayerId]), new { before = Audit(current), after = Audit(saved), descriptionChanged = current?.Description != saved.Description });
        return new(saved, writes);
    }, ct);
    }
    public Task<System.Text.Json.JsonElement> TransitionExpenseAsync(Actor actor, string key, string id, string expenseId, long version, bool restore, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, $"group:{id}:expense:{expenseId}:{restore}", new { version }, async () =>
    {
        var (row, group, balances, balanceRows) = await SnapshotAsync(id, actor.User.Id, ct); var expenseRow = await store.GetAsync(row.Pk, $"EXPENSE#{expenseId}", ct) ?? throw NotFound(); var current = expenseRow.Deserialize<Expense>();
        var saved = restore ? ExpenseService.Restore(group, current, actor.User.Id, version, DateTimeOffset.UtcNow) : ExpenseService.Delete(group, current, actor.User.Id, version, DateTimeOffset.UtcNow);
        var next = LedgerEngine.ApplyExpense(balances, restore ? saved : current, restore ? 1 : -1); var updated = group with { Version = group.Version + 1 };
        var writes = new List<StoreMutation> { PutGroup(row, updated), StoreMutation.Put(StoreRow.Create(row.Pk, expenseRow.Sk, saved.Version, saved), expenseRow.Version) };
        writes.AddRange(await receipts.ExpenseTransitionAsync(saved, restore, DateTimeOffset.UtcNow, ct));
        AddBalances(writes, row.Pk, next, balanceRows); AddEvent(writes, updated, actor.User.Id, restore ? "expense_restored" : "expense_deleted", expenseId, current.Participants.Select(p => p.ParticipantId).Append(current.PayerId), new { before = Audit(current), after = Audit(saved) }); return new(saved, writes);
    }, ct);
    public Task<System.Text.Json.JsonElement> SettleAsync(Actor actor, string key, string id, SettlementRequest input, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, $"group:{id}:settlement:{input.Id}", input, async () =>
    {
        if (!Guid.TryParse(input.Id, out _)) throw new DomainException(422, "id_invalid", "Payment ID must be a UUID.");
        var (row, group, balances, balanceRows) = await SnapshotAsync(id, actor.User.Id, ct);
        if (await store.GetAsync(row.Pk, $"PAYMENT#{input.Id}", ct) is not null) throw new DomainException(409, "payment_exists", "This payment is already recorded.");
        var draft = new Settlement(input.Id, id, input.FromId, input.ToId, input.AmountPaise, input.Method, 0, false, actor.User.Id, DateTimeOffset.UtcNow);
        var saved = SettlementRules.Create(group, draft, balances, actor.User.Id, DateTimeOffset.UtcNow); var next = LedgerEngine.ApplySettlement(balances, saved); var updated = group with { Version = group.Version + 1 };
        var writes = new List<StoreMutation> { PutGroup(row, updated), StoreMutation.Put(StoreRow.Create(row.Pk, $"PAYMENT#{saved.Id}", 1, saved), null) };
        AddBalances(writes, row.Pk, next, balanceRows); AddEvent(writes, updated, actor.User.Id, "payment_recorded", saved.Id, [saved.FromId, saved.ToId]); return new(saved, writes);
    }, ct);
    public Task<System.Text.Json.JsonElement> DisputeAsync(Actor actor, string key, string id, string paymentId, long version, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, $"group:{id}:dispute:{paymentId}", new { version }, async () =>
    {
        var (row, group, balances, balanceRows) = await SnapshotAsync(id, actor.User.Id, ct); var paymentRow = await store.GetAsync(row.Pk, $"PAYMENT#{paymentId}", ct) ?? throw NotFound(); var current = paymentRow.Deserialize<Settlement>();
        var saved = SettlementRules.Dispute(group, current, actor.User.Id, version); var next = LedgerEngine.ApplySettlement(balances, current, -1); var updated = group with { Version = group.Version + 1 };
        var writes = new List<StoreMutation> { PutGroup(row, updated), StoreMutation.Put(StoreRow.Create(row.Pk, paymentRow.Sk, saved.Version, saved), paymentRow.Version) };
        AddBalances(writes, row.Pk, next, balanceRows); AddEvent(writes, updated, actor.User.Id, "payment_disputed", paymentId, [saved.FromId, saved.ToId]); return new(saved, writes);
    }, ct);
    public async Task<object> PaymentsAsync(string id, string userId, CancellationToken ct = default) { await RequireGroupAsync(id, userId, ct); return new { items = (await AllAsync($"GROUP#{id}", "PAYMENT#", ct)).Select(r => r.Deserialize<Settlement>()) }; }
    public Task<System.Text.Json.JsonElement> LeaveAsync(Actor actor, string key, string id, LeaveRequest input, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, $"group:{id}:leave", input, async () =>
    {
        var (row, group, balances, _) = await SnapshotAsync(id, actor.User.Id, ct); GroupRules.EnsureCanLeave(group, actor.User.Id, input.AcknowledgeBalance, balances);
        var updated = group with { Version = group.Version + 1, Members = group.Members.Select(m => m.UserId == actor.User.Id ? m with { HasLeft = true } : m).ToArray() };
        var writes = new List<StoreMutation> { PutGroup(row, updated) }; AddEvent(writes, updated, actor.User.Id, "member_left", id); return new(new { left = true }, writes);
    }, ct);
    public Task<System.Text.Json.JsonElement> DeleteGroupAsync(Actor actor, string key, string id, long version, CancellationToken ct = default) => commands.ExecuteAsync(actor, key, $"group:{id}:delete", new { version }, async () =>
    {
        var (row, group, balances, _) = await SnapshotAsync(id, actor.User.Id, ct); GroupRules.EnsureCanDelete(group, actor.User.Id, version, balances);
        var updated = group with { Deleted = true, Archived = true, Version = group.Version + 1 }; var writes = new List<StoreMutation> { PutGroup(row, updated) };
        writes.AddRange(await receipts.GroupDeletedAsync(id, DateTimeOffset.UtcNow, ct));
        AddEvent(writes, updated, actor.User.Id, "group_deleted", id); return new(new { deleted = true }, writes);
    }, ct);
    public async Task<object> HomeAsync(string userId, CancellationToken ct = default)
    {
        var friends = new Dictionary<string, (string Name, long Net)>();
        foreach (var edge in await AllAsync($"USER#{userId}", "GROUP#", ct))
        {
            var row = await store.GetAsync($"GROUP#{edge.Sk[6..]}", "META", ct); if (row is null) continue; var group = row.Deserialize<Group>(); if (group.Deleted) continue;
            var snapshot = await SnapshotAsync(group.Id, userId, ct); group = snapshot.Item2; var balances = snapshot.Item3;
            foreach (var member in group.Members.Where(m => m.UserId == userId))
            {
                var own = balances.First(b => b.ParticipantId == member.Id);
                foreach (var pair in own.Counterparties)
                {
                    var other = group.Members.First(m => m.Id == pair.Key); if (other.UserId == userId) continue;
                    var person = other.UserId is null ? null : await store.GetAsync($"USER#{other.UserId}", "PROFILE", ct);
                    var name = person?.Deserialize<UserAccount>().Status == "active" ? person.Deserialize<UserAccount>().DisplayName : other.IsDeleted ? "Deleted user" : other.DisplayName;
                    var friendId = other.UserId ?? $"{group.Id}:{other.Id}"; var old = friends.GetValueOrDefault(friendId); friends[friendId] = (name, old.Net + pair.Value);
                }
            }
        }
        var values = friends.Select(x => new { id = x.Key, displayName = x.Value.Name, netPaise = x.Value.Net }).Where(x => x.netPaise != 0).ToArray();
        return new { netPaise = values.Sum(x => x.netPaise), owedPaise = values.Where(x => x.netPaise > 0).Sum(x => x.netPaise), owingPaise = -values.Where(x => x.netPaise < 0).Sum(x => x.netPaise), friends = values };
    }
    public async Task<object> ActivityAsync(string userId, string? id, CancellationToken ct = default)
    {
        var items = new List<ActivityDetail>();
        var actorNames = new Dictionary<string, string>(StringComparer.Ordinal);
        if (id is not null) await RequireGroupAsync(id, userId, ct);
        var ids = id is null ? (await AllAsync($"USER#{userId}", "GROUP#", ct)).Select(e => e.Sk[6..]).ToArray() : [id];
        foreach (var gid in ids)
        {
            try { await RequireGroupAsync(gid, userId, ct); } catch (DomainException ex) when (ex.Status == 404) { continue; }
            var events = await store.QueryAsync($"GROUP#{gid}", "EVENT#", 100, ct: ct);
            foreach (var row in events.Items)
            {
                var activity = row.Deserialize<Activity>();
                if (!actorNames.TryGetValue(activity.ActorId, out var actorName))
                {
                    var account = await store.GetAsync($"USER#{activity.ActorId}", "PROFILE", ct);
                    var actor = account?.Deserialize<UserAccount>(); actorName = actor?.Status == "active" ? actor.DisplayName : "Deleted user";
                    actorNames.Add(activity.ActorId, actorName);
                }
                System.Text.Json.JsonElement? changes = row.Data.TryGetProperty("changes", out var value) && value.ValueKind != System.Text.Json.JsonValueKind.Null ? value.Clone() : null;
                items.Add(new(activity.Id, activity.GroupId, activity.Kind, activity.ActorId, activity.Description, activity.CreatedAt, activity.EntityId, actorName, changes));
            }
        }
        return new { items = items.OrderByDescending(x => x.CreatedAt).Take(100) };
    }
    public async Task<Group> RequireGroupAsync(string id, string userId, CancellationToken ct = default)
    {
        var row = await store.GetAsync($"GROUP#{id}", "META", ct) ?? throw NotFound(); var group = row.Deserialize<Group>();
        if (group.Deleted || !group.Members.Any(m => m.UserId == userId && !m.IsDeleted)) throw NotFound(); return group;
    }
    public async Task<List<StoreRow>> AllAsync(string pk, string prefix, CancellationToken ct = default)
    {
        var rows = new List<StoreRow>(); string? cursor = null; do { var page = await store.QueryAsync(pk, prefix, 100, cursor, ct); rows.AddRange(page.Items); cursor = page.NextCursor; } while (cursor is not null); return rows;
    }
    private async Task<(StoreRow, Group, IReadOnlyList<Balance>, IReadOnlyList<StoreRow>)> SnapshotAsync(string id, string userId, CancellationToken ct)
    {
        for (var i = 0; i < 5; i++) { var group = await RequireGroupAsync(id, userId, ct); var rows = (await store.QueryAsync($"GROUP#{id}", "BALANCE#", 100, ct: ct)).Items; var after = await store.GetAsync($"GROUP#{id}", "META", ct) ?? throw NotFound(); if (after.Version == group.Version) return (after, group, rows.Select(b => b.Deserialize<Balance>()).ToArray(), rows); }
        throw new DomainException(409, "group_busy", "This group changed. Refresh and try again.");
    }
    private async Task<GroupDetail> DetailAsync(Group group, IReadOnlyList<Balance> balances, CancellationToken ct)
    {
        var members = new List<MemberDetail>(); var now = DateTimeOffset.UtcNow;
        foreach (var member in group.Members) { if (member.UserId is null) { members.Add(MemberDetail.From(member, now)); continue; } var account = await store.GetAsync($"USER#{member.UserId}", "PROFILE", ct); var user = account?.Deserialize<UserAccount>(); members.Add(MemberDetail.From(member with { DisplayName = user?.Status == "active" ? user.DisplayName : "Deleted user", IsDeleted = user?.Status != "active" }, now)); }
        return new(group.Id, group.Name, group.Type, group.Archived, group.Version, group.CreatorId, members, balances);
    }
    private static void AddBalances(List<StoreMutation> writes, string pk, IReadOnlyList<Balance> balances, IReadOnlyList<StoreRow> rows)
    {
        foreach (var balance in balances) { var prior = rows.FirstOrDefault(r => r.Sk == $"BALANCE#{balance.ParticipantId}"); writes.Add(StoreMutation.Put(StoreRow.Create(pk, $"BALANCE#{balance.ParticipantId}", (prior?.Version ?? 0) + 1, balance), prior?.Version)); }
    }
    private static StoreMutation PutGroup(StoreRow row, Group group) => StoreMutation.Put(StoreRow.Create(row.Pk, row.Sk, group.Version, group), row.Version);
    private static string DateKey(Expense expense) => $"EXPENSEDATE#{DateOnly.MaxValue.DayNumber - expense.Date.DayNumber:D7}#{expense.Id}";
    private static void RequireVersion(long current, long expected) { if (current != expected) throw new DomainException(409, "version_conflict", "This group changed — review latest."); }
    private static DomainException NotFound() => new(404, "not_found", "Not found.");
    private static object? Audit(Expense? expense) => expense is null ? null : new { expense.AmountPaise, expense.Date, expense.PayerId, expense.Mode, expense.Shares, expense.Version, expense.DeletedAt, expense.ReceiptId, expense.ReceiptRevision, expense.DisplaySplitKind };
    private static void AddEvent(List<StoreMutation> writes, Group group, string actorId, string kind, string entityId, IEnumerable<string>? recipients = null, object? changes = null)
    {
        var id = Ids.New(); var activity = new Activity(id, group.Id, kind, actorId, kind.Replace('_', ' '), DateTimeOffset.UtcNow, entityId);
        var payload = new { activity.Id, activity.GroupId, activity.Kind, activity.ActorId, activity.Description, activity.CreatedAt, activity.EntityId, recipientParticipantIds = recipients?.Distinct(StringComparer.Ordinal).ToArray(), changes };
        writes.Add(StoreMutation.Put(StoreRow.Create($"GROUP#{group.Id}", $"EVENT#{long.MaxValue - group.Version:D19}#{id}", 1, payload), null));
        writes.Add(StoreMutation.Put(StoreRow.Create("OUTBOX", id, 1, payload), null));
    }
}
