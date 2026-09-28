using System.Text;
using System.Security.Cryptography;
using Hisaab.Api.Billing;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Identity;

public sealed class IdentityService(IAtomicStore store, IProviderVerifier verifier, AppleTokens apple, BillingService billing, IConfiguration configuration, IHostEnvironment environment, PhoneOtpService phone)
{
    public async Task<object> ChallengeAsync(CancellationToken ct = default)
    {
        var nonce = Ids.Token(); var until = DateTimeOffset.UtcNow.AddMinutes(10);
        await store.TransactAsync([StoreMutation.Put(StoreRow.Create($"CHALLENGE#{Ids.Hash(nonce)}", "META", 1, new ChallengeRecord(until), until.ToUnixTimeSeconds()), null)], ct);
        return new { nonce };
    }
    public async Task<SessionResult> DevAsync(string displayName, CancellationToken ct = default)
    {
        if (!environment.IsDevelopment() || !configuration.GetValue<bool>("Hisaab:DevAuth")) throw new DomainException(404, "not_found", "Not found.");
        var user = new UserAccount(Ids.New(), Name(displayName), null, "active", DateTimeOffset.UtcNow);
        var writes = new List<StoreMutation> { StoreMutation.Put(StoreRow.Create($"USER#{user.Id}", "PROFILE", 1, user), null) };
        return await CreateSessionAsync(user, writes, ct);
    }
    public async Task<SessionResult> SignInAsync(SignInRequest request, CancellationToken ct = default)
    {
        var challenge = await ChallengeRowAsync(request.Nonce, ct);
        var proof = await VerifyAsync(request, challenge, "sign-in", null, ct);
        var identity = proof.Identity; challenge = proof.Challenge;
        var pk = IdentityKey(identity.Provider, identity.Subject);
        var row = await store.GetAsync(pk, "OWNER", ct);
        var writes = new List<StoreMutation> { StoreMutation.Delete(challenge.Pk, challenge.Sk, challenge.Version) };
        UserAccount user;
        if (row is not null)
        {
            var known = row.Deserialize<ProviderIdentity>(); var account = await store.GetAsync($"USER#{known.UserId}", "PROFILE", ct);
            if (account is null || account.Deserialize<UserAccount>().Status != "active") throw new DomainException(401, "account_unavailable", "This account is unavailable.");
            user = account.Deserialize<UserAccount>();
            if (identity.Provider != "phone") user = user with { Email = identity.Email };
            writes.Add(StoreMutation.Put(StoreRow.Create(account.Pk, account.Sk, account.Version + 1, user), account.Version));
            var updated = known with { Email = identity.Email, Audience = identity.Audience };
            if (identity.Provider == "apple")
                updated = updated with { EncryptedRefreshToken = await apple.ExchangeAsync(request.AuthorizationCode ?? "", identity.Audience, identity.Subject, request.Nonce, ct) };
            writes.Add(StoreMutation.Put(StoreRow.Create(pk, "OWNER", row.Version + 1, updated), row.Version));
            if (known.Email is not null && !string.Equals(known.Email, identity.Email, StringComparison.OrdinalIgnoreCase))
            {
                var oldContact = await store.GetAsync(ContactKey(known.Email), $"ACCOUNT#{user.Id}", ct);
                if (oldContact is not null) writes.Add(StoreMutation.Delete(oldContact.Pk, oldContact.Sk, oldContact.Version));
            }
            if (identity.Email is not null)
            {
                var contact = await store.GetAsync(ContactKey(identity.Email), $"ACCOUNT#{user.Id}", ct);
                writes.Add(StoreMutation.Put(StoreRow.Create(ContactKey(identity.Email), $"ACCOUNT#{user.Id}", (contact?.Version ?? 0) + 1, new { userId = user.Id, authoritative = identity.AuthoritativeEmail }), contact?.Version));
            }
        }
        else
        {
            var contact = identity.Email is null ? null : await store.QueryAsync(ContactKey(identity.Email), "ACCOUNT#", 2, ct: ct);
            if (contact?.Items.Count > 0) throw new DomainException(409, "account_link_required", "An account uses this email. Sign in to that account, then link this provider in Settings after reauthentication.");
            user = new UserAccount(Ids.New(), Name(request.DisplayName ?? "Hisaab member"), identity.Email, "active", DateTimeOffset.UtcNow);
            var refresh = identity.Provider == "apple" ? await apple.ExchangeAsync(request.AuthorizationCode ?? "", identity.Audience, identity.Subject, request.Nonce, ct) : null;
            writes.Add(StoreMutation.Put(StoreRow.Create(pk, "OWNER", 1, new ProviderIdentity(user.Id, identity.Provider, identity.Subject, identity.Email, refresh, identity.Audience)), null));
            writes.Add(StoreMutation.Put(StoreRow.Create($"USER#{user.Id}", "PROFILE", 1, user), null));
            writes.Add(StoreMutation.Put(StoreRow.Create($"USER#{user.Id}", $"IDENTITY#{Ids.Hash(pk)}", 1, new { key = pk }), null));
            if (identity.Email is not null) writes.Add(StoreMutation.Put(StoreRow.Create(ContactKey(identity.Email), $"ACCOUNT#{user.Id}", 1, new { userId = user.Id, authoritative = identity.AuthoritativeEmail }), null));
        }
        try { return await CreateSessionAsync(user, writes, ct, verifiedInviteEmail: identity.AuthoritativeEmail ? identity.Email : null); }
        catch (StoreConflictException) { throw new DomainException(409, "sign_in_retry", "This sign-in was already used or the account changed. Start sign-in again."); }
    }
    public async Task<UserAccount> LinkAsync(Actor actor, SignInRequest request, CancellationToken ct = default)
    {
        Recent(actor);
        var challenge = await ChallengeRowAsync(request.Nonce, ct);
        var proof = await VerifyAsync(request, challenge, "link", actor, ct);
        var verified = proof.Identity; challenge = proof.Challenge; var pk = IdentityKey(verified.Provider, verified.Subject);
        var existing = await store.GetAsync(pk, "OWNER", ct);
        if (existing is not null && existing.Deserialize<ProviderIdentity>().UserId != actor.User.Id) throw new DomainException(409, "account_merge_required", "This sign-in belongs to another Hisaab account. Contact support to preserve both accounts' records.");
        if (existing is not null)
        {
            await store.TransactAsync([StoreMutation.Condition($"USER#{actor.User.Id}", "PROFILE", actor.AccountVersion), StoreMutation.Delete(challenge.Pk, challenge.Sk, challenge.Version)], ct);
            return actor.User;
        }
        var refresh = verified.Provider == "apple" ? await apple.ExchangeAsync(request.AuthorizationCode ?? "", verified.Audience, verified.Subject, request.Nonce, ct) : null;
        var session = await store.GetAsync($"SESSION#{actor.SessionHash}", "META", ct) ?? throw new DomainException(401, "session_invalid", "Sign in again.");
        var linkedSession = session.Deserialize<SessionRecord>() with { VerifiedInviteEmail = verified.AuthoritativeEmail ? verified.Email : null };
        var linkWrites = new List<StoreMutation>{
            StoreMutation.Condition($"USER#{actor.User.Id}","PROFILE",actor.AccountVersion),
            StoreMutation.Put(StoreRow.Create(session.Pk,session.Sk,session.Version+1,linkedSession,linkedSession.RefreshExpiresAt.ToUnixTimeSeconds()),session.Version),
            StoreMutation.Delete(challenge.Pk,challenge.Sk,challenge.Version),
            StoreMutation.Put(StoreRow.Create(pk,"OWNER",1,new ProviderIdentity(actor.User.Id,verified.Provider,verified.Subject,verified.Email,refresh,verified.Audience)),null),
            StoreMutation.Put(StoreRow.Create($"USER#{actor.User.Id}",$"IDENTITY#{Ids.Hash(pk)}",1,new {key=pk}),null)
        };
        if (verified.Email is not null)
        {
            var contact = await store.GetAsync(ContactKey(verified.Email), $"ACCOUNT#{actor.User.Id}", ct);
            linkWrites.Add(StoreMutation.Put(StoreRow.Create(ContactKey(verified.Email), $"ACCOUNT#{actor.User.Id}", (contact?.Version ?? 0) + 1, new { userId = actor.User.Id, authoritative = verified.AuthoritativeEmail }), contact?.Version));
        }
        await store.TransactAsync(linkWrites, ct);
        return actor.User;
    }
    public async Task<SessionResult> ReauthenticatePhoneAsync(Actor actor, PhoneReauthenticationRequest request, CancellationToken ct = default)
    {
        var challenge = await ChallengeRowAsync(request.Nonce, ct);
        var proof = await phone.VerifyAsync(challenge, request.Code, "reauthenticate", actor, ct);
        var owner = await store.GetAsync(IdentityKey("phone", proof.Identity.Subject), "OWNER", ct);
        if (owner?.Deserialize<ProviderIdentity>().UserId != actor.User.Id) throw new DomainException(401, "phone_code_invalid", "Use the phone number linked to this account.");
        var session = await store.GetAsync($"SESSION#{actor.SessionHash}", "META", ct) ?? throw new DomainException(401, "session_invalid", "Sign in again.");
        var data = session.Deserialize<SessionRecord>();
        var refresh = await store.GetAsync($"REFRESH#{data.RefreshHash}", "META", ct);
        var index = await store.GetAsync($"USER#{actor.User.Id}", $"SESSION#{actor.SessionHash}", ct);
        var writes = new List<StoreMutation> {
            StoreMutation.Condition($"USER#{actor.User.Id}", "PROFILE", actor.AccountVersion),
            StoreMutation.Condition(owner.Pk, owner.Sk, owner.Version),
            StoreMutation.Delete(proof.Challenge.Pk, proof.Challenge.Sk, proof.Challenge.Version),
            StoreMutation.Delete(session.Pk, session.Sk, session.Version)
        };
        if (refresh is not null) writes.Add(StoreMutation.Delete(refresh.Pk, refresh.Sk, refresh.Version));
        if (index is not null) writes.Add(StoreMutation.Delete(index.Pk, index.Sk, index.Version));
        try { return await CreateSessionAsync(actor.User, writes, ct, previousSessionHash: actor.SessionHash); }
        catch (StoreConflictException) { throw new DomainException(409, "sign_in_retry", "This sign-in was already used or the account changed. Start sign-in again."); }
    }
    private async Task<PhoneVerification> VerifyAsync(SignInRequest request, StoreRow challenge, string purpose, Actor? actor, CancellationToken ct)
    {
        if (request.Provider == "phone") return await phone.VerifyAsync(challenge, request.IdToken, purpose, actor, ct);
        if (PhoneOtpService.IsPhoneChallenge(challenge)) throw new DomainException(401, "challenge_invalid", "Start sign-in again.");
        return new(await verifier.VerifyAsync(request, ct), challenge);
    }
    public async Task<Actor> AuthenticateAsync(string token, CancellationToken ct = default)
    {
        if (token.Length != 64) throw new DomainException(401, "session_invalid", "Sign in to continue.");
        var hash = Ids.Hash(token); var row = await store.GetAsync($"SESSION#{hash}", "META", ct);
        if (row is null) throw new DomainException(401, "session_invalid", "Sign in to continue.");
        var session = row.Deserialize<SessionRecord>();
        if (session.AccessExpiresAt <= DateTimeOffset.UtcNow) throw new DomainException(401, "session_expired", "Your session expired. Sign in again.");
        var user = await store.GetAsync($"USER#{session.UserId}", "PROFILE", ct);
        if (user is null || user.Deserialize<UserAccount>().Status != "active") throw new DomainException(401, "account_unavailable", "This account is unavailable.");
        return new(user.Deserialize<UserAccount>(), user.Version, hash, row.Version, session.CreatedAt);
    }
    public async Task<SessionResult> RefreshAsync(string refresh, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(refresh) || refresh.Length != 64) throw new DomainException(401, "refresh_invalid", "Sign in again.");
        var link = await store.GetAsync($"REFRESH#{Ids.Hash(refresh)}", "META", ct);
        if (link is null) throw new DomainException(401, "refresh_invalid", "Sign in again.");
        var hash = link.Data.GetProperty("sessionHash").GetString()!;
        var session = await store.GetAsync($"SESSION#{hash}", "META", ct);
        if (session is null || session.Deserialize<SessionRecord>().RefreshExpiresAt <= DateTimeOffset.UtcNow) throw new DomainException(401, "refresh_expired", "Sign in again.");
        var data = session.Deserialize<SessionRecord>(); var user = await store.GetAsync($"USER#{data.UserId}", "PROFILE", ct);
        if (user is null || user.Deserialize<UserAccount>().Status != "active") throw new DomainException(401, "account_unavailable", "This account is unavailable.");
        var index = await store.GetAsync($"USER#{data.UserId}", $"SESSION#{hash}", ct);
        var writes = new List<StoreMutation> { StoreMutation.Delete(session.Pk, session.Sk, session.Version), StoreMutation.Delete(link.Pk, link.Sk, link.Version), StoreMutation.Condition(user.Pk, user.Sk, user.Version) };
        if (index is not null) writes.Add(StoreMutation.Delete(index.Pk, index.Sk, index.Version));
        try { return await CreateSessionAsync(user.Deserialize<UserAccount>(), writes, ct, data.CreatedAt, hash, data.VerifiedInviteEmail); }
        catch (StoreConflictException) { throw new DomainException(401, "refresh_reused", "This refresh credential has already been used. Sign in again."); }
    }
    public async Task SignOutAsync(Actor actor, CancellationToken ct = default)
    {
        var row = await store.GetAsync($"SESSION#{actor.SessionHash}", "META", ct); if (row is null) return;
        var writes = new List<StoreMutation> { StoreMutation.Delete(row.Pk, row.Sk, row.Version) };
        var refresh = await store.GetAsync($"REFRESH#{row.Deserialize<SessionRecord>().RefreshHash}", "META", ct); if (refresh is not null) writes.Add(StoreMutation.Delete(refresh.Pk, refresh.Sk, refresh.Version));
        var index = await store.GetAsync($"USER#{actor.User.Id}", $"SESSION#{actor.SessionHash}", ct); if (index is not null) writes.Add(StoreMutation.Delete(index.Pk, index.Sk, index.Version));
        var devices = await store.QueryAsync($"USER#{actor.User.Id}", "DEVICE#", 100, ct: ct);
        foreach (var device in devices.Items.Where(d => d.Data.TryGetProperty("sessionHash", out var value) && value.GetString() == actor.SessionHash)) writes.Add(StoreMutation.Delete(device.Pk, device.Sk, device.Version));
        await store.TransactAsync(writes, ct);
    }
    private async Task<SessionResult> CreateSessionAsync(UserAccount user, List<StoreMutation> writes, CancellationToken ct, DateTimeOffset? authenticatedAt = null, string? previousSessionHash = null, string? verifiedInviteEmail = null)
    {
        var access = Ids.Token(); var refresh = Ids.Token(); var hash = Ids.Hash(access); var now = DateTimeOffset.UtcNow; var until = now.AddDays(30);
        var session = new SessionRecord(user.Id, Ids.Hash(refresh), now.AddMinutes(30), until, authenticatedAt ?? now, verifiedInviteEmail);
        writes.Add(StoreMutation.Put(StoreRow.Create($"SESSION#{hash}", "META", 1, session, until.ToUnixTimeSeconds()), null));
        writes.Add(StoreMutation.Put(StoreRow.Create($"REFRESH#{session.RefreshHash}", "META", 1, new { sessionHash = hash }, until.ToUnixTimeSeconds()), null));
        writes.Add(StoreMutation.Put(StoreRow.Create($"USER#{user.Id}", $"SESSION#{hash}", 1, new { sessionHash = hash }, until.ToUnixTimeSeconds()), null));
        if (previousSessionHash is not null)
        {
            var devices = await store.QueryAsync($"USER#{user.Id}", "DEVICE#", 100, ct: ct);
            foreach (var device in devices.Items.Where(d => d.Data.GetProperty("sessionHash").GetString() == previousSessionHash))
            {
                var data = device.Data;
                writes.Add(StoreMutation.Put(StoreRow.Create(device.Pk, device.Sk, device.Version + 1, new { id = data.GetProperty("id").GetString(), token = data.GetProperty("token").GetString(), platform = data.GetProperty("platform").GetString(), sessionHash = hash }), device.Version));
            }
        }
        await store.TransactAsync(writes, ct);
        return new(access, refresh, user, await billing.GetAsync(user.Id, ct));
    }
    private async Task<StoreRow> ChallengeRowAsync(string nonce, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(nonce) || nonce.Length != 64) throw new DomainException(401, "challenge_invalid", "Start sign-in again.");
        var row = await store.GetAsync($"CHALLENGE#{Ids.Hash(nonce)}", "META", ct);
        if (row is null || row.Deserialize<ChallengeRecord>().ExpiresAt <= DateTimeOffset.UtcNow) throw new DomainException(401, "challenge_expired", "Start sign-in again.");
        return row;
    }
    public string ContactKey(string contact)
    {
        var secret = configuration["Hisaab:ContactHashKey"];
        if (string.IsNullOrEmpty(secret)) { if (!environment.IsDevelopment()) throw new DomainException(503, "identity_unconfigured", "Identity contact lookup is not configured."); secret = "local-development-contact-index-not-for-production"; }
        return "CONTACT#" + Convert.ToHexString(HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), Encoding.UTF8.GetBytes(contact.Trim().ToLowerInvariant()))).ToLowerInvariant();
    }
    public static string IdentityKey(string provider, string subject) => $"IDENTITY#{provider}#{Ids.Hash(subject)}";
    public static string Name(string? input) { var value = (input ?? "").Trim(); if (value.Length is < 1 or > 100) throw new DomainException(422, "name_invalid", "Enter a name between 1 and 100 characters."); return value; }
    public static void Recent(Actor actor) { if (actor.AuthenticatedAt < DateTimeOffset.UtcNow.AddMinutes(-10)) throw new DomainException(401, "reauthentication_required", "Sign in again to confirm this account change."); }
}
