using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Hisaab.Api.Identity;
using Hisaab.Application.Storage;
using Hisaab.Domain;

namespace Hisaab.Api.Shared;

public sealed class PushService(IAtomicStore store, IHttpClientFactory clients, IConfiguration config)
{
    private readonly SemaphoreSlim _tokenGate = new(1, 1);
    private string? _accessToken;
    private DateTimeOffset _accessTokenExpires;

    public async Task DeliverAsync(StoreRow outbox, CancellationToken ct = default)
    {
        var activity = outbox.Deserialize<Activity>();
        var category = activity.Kind.StartsWith("expense_", StringComparison.Ordinal) ? "expenses"
            : activity.Kind.StartsWith("payment_", StringComparison.Ordinal) ? "payments"
            : activity.Kind.StartsWith("invite_", StringComparison.Ordinal) ? "invites" : null;
        if (category is null) return;
        var groupRow = await store.GetAsync($"GROUP#{activity.GroupId}", "META", ct);
        if (groupRow is null) return;
        var group = groupRow.Deserialize<Group>();
        if (group.Deleted) return;
        var participantIds = await RecipientParticipantsAsync(outbox, activity, group, ct);
        var recipients = group.Members.Where(m => participantIds.Contains(m.Id) && m.UserId is not null &&
                m.UserId != activity.ActorId && !m.HasLeft && !m.IsDeleted)
            .Select(m => m.UserId!).Distinct(StringComparer.Ordinal);
        foreach (var userId in recipients)
        {
            ct.ThrowIfCancellationRequested();
            var account = await store.GetAsync($"USER#{userId}", "PROFILE", ct);
            if (account is null || account.Deserialize<UserAccount>().Status != "active") continue;
            var preferenceRow = await store.GetAsync(account.Pk, "PREFS", ct);
            if (!Enabled(preferenceRow?.Deserialize<NotificationPreferences>() ?? new(), category)) continue;
            var devices = await store.QueryAsync(account.Pk, "DEVICE#", 100, ct: ct);
            foreach (var device in devices.Items)
                await DeliverDeviceAsync(activity, category, account, preferenceRow, device, ct);
        }
    }

    private async Task<HashSet<string>> RecipientParticipantsAsync(StoreRow outbox, Activity activity, Group group, CancellationToken ct)
    {
        if (outbox.Data.TryGetProperty("recipientParticipantIds", out var stored) && stored.ValueKind == JsonValueKind.Array)
            return stored.EnumerateArray().Select(x => x.GetString()!).Where(x => !string.IsNullOrWhiteSpace(x)).ToHashSet(StringComparer.Ordinal);
        if (activity.Kind.StartsWith("expense_", StringComparison.Ordinal))
        {
            var row = await store.GetAsync($"GROUP#{activity.GroupId}", $"EXPENSE#{activity.EntityId}", ct);
            if (row is null) return [];
            var expense = row.Deserialize<Expense>();
            return expense.Participants.Select(p => p.ParticipantId).Append(expense.PayerId).ToHashSet(StringComparer.Ordinal);
        }
        if (activity.Kind.StartsWith("payment_", StringComparison.Ordinal))
        {
            var row = await store.GetAsync($"GROUP#{activity.GroupId}", $"PAYMENT#{activity.EntityId}", ct);
            if (row is null) return [];
            var payment = row.Deserialize<Settlement>();
            return [payment.FromId, payment.ToId];
        }
        return group.Members.Where(m => m.UserId == group.CreatorId).Select(m => m.Id).ToHashSet(StringComparer.Ordinal);
    }

    private async Task DeliverDeviceAsync(Activity activity, string category, StoreRow account, StoreRow? preferences,
        StoreRow device, CancellationToken ct)
    {
        if (!device.Data.TryGetProperty("sessionHash", out var hashValue) || string.IsNullOrWhiteSpace(hashValue.GetString())) return;
        var session = await store.GetAsync($"SESSION#{hashValue.GetString()}", "META", ct);
        var user = account.Deserialize<UserAccount>();
        if (session is null || session.Deserialize<SessionRecord>() is not { } sessionData ||
            sessionData.UserId != user.Id || sessionData.RefreshExpiresAt <= DateTimeOffset.UtcNow) return;
        var token = device.Data.GetProperty("token").GetString();
        if (string.IsNullOrWhiteSpace(token)) return;
        var markerPk = $"DELIVERY#{activity.Id}";
        var markerSk = $"{user.Id}#{device.Sk}#{Ids.Hash(token)}";
        var marker = await store.GetAsync(markerPk, markerSk, ct);
        var previous = marker?.Deserialize<DeliveryMarker>();
        if (previous?.Status == "sent") return;
        if (previous?.LeaseUntil > DateTimeOffset.UtcNow)
            throw new InvalidOperationException("Notification delivery is already in progress; retry the outbox item.");
        var credentials = Credentials(); // Never consume pending work when a real delivery cannot be configured.
        var lease = new DeliveryMarker("sending", DateTimeOffset.UtcNow.AddMinutes(2), Ids.New());
        var claimed = StoreRow.Create(markerPk, markerSk, (marker?.Version ?? 0) + 1, lease,
            DateTimeOffset.UtcNow.AddDays(30).ToUnixTimeSeconds());
        var checks = new List<StoreMutation>
        {
            StoreMutation.Condition(account.Pk, account.Sk, account.Version),
            StoreMutation.Condition(session.Pk, session.Sk, session.Version),
            StoreMutation.Condition(device.Pk, device.Sk, device.Version),
            StoreMutation.Condition(account.Pk, "PREFS", preferences?.Version),
            StoreMutation.Put(claimed, marker?.Version)
        };
        await store.TransactAsync(checks, ct);
        try
        {
            var accessToken = await AccessTokenAsync(credentials, ct);
            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"https://fcm.googleapis.com/v1/projects/{Uri.EscapeDataString(credentials.ProjectId)}/messages:send");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            request.Content = JsonContent.Create(new
            {
                message = new
                {
                    token,
                    notification = new { title = "Hisaab", body = "You have a new shared-expense update. Open Hisaab to view it." },
                    data = new { eventId = activity.Id, groupId = activity.GroupId, category },
                    android = new { notification = new { tag = activity.Id } },
                    apns = new { headers = new Dictionary<string, string> { ["apns-collapse-id"] = activity.Id } }
                }
            });
            using var response = await clients.CreateClient().SendAsync(request, ct);
            var unregistered = !response.IsSuccessStatusCode && IsUnregistered(await response.Content.ReadAsStringAsync(ct));
            if (!response.IsSuccessStatusCode && !unregistered)
            {
                if (response.StatusCode == HttpStatusCode.Unauthorized) _accessToken = null;
                throw new InvalidOperationException($"FCM delivery failed with HTTP {(int)response.StatusCode}; pending work retained.");
            }
            var completed = StoreMutation.Put(StoreRow.Create(markerPk, markerSk, claimed.Version + 1,
                lease with { Status = "sent", LeaseUntil = DateTimeOffset.MinValue }, claimed.ExpiresAtUnixSeconds), claimed.Version);
            if (unregistered)
            {
                var current = await store.GetAsync(device.Pk, device.Sk, ct);
                if (current?.Version == device.Version)
                {
                    await store.TransactAsync([completed, StoreMutation.Delete(device.Pk, device.Sk, device.Version)], ct);
                    return;
                }
            }
            await store.TransactAsync([completed], ct);
        }
        catch
        {
            // Release a failed lease for the next run; cancellation/crash leaves a bounded lease.
            if (!ct.IsCancellationRequested)
            {
                try
                {
                    await store.TransactAsync([StoreMutation.Put(StoreRow.Create(markerPk, markerSk, claimed.Version + 1,
                        lease with { Status = "pending", LeaseUntil = DateTimeOffset.MinValue }, claimed.ExpiresAtUnixSeconds), claimed.Version)], ct);
                }
                catch (StoreConflictException) { }
            }
            throw;
        }
    }

    private FirebaseCredentials Credentials()
    {
        var text = config["Hisaab:Firebase:ServiceAccountJson"];
        if (string.IsNullOrWhiteSpace(text)) throw new InvalidOperationException("Firebase credentials are unavailable; pending notifications retained.");
        using var json = JsonDocument.Parse(text);
        var root = json.RootElement;
        if (!root.TryGetProperty("type", out var type) || type.GetString() != "service_account")
            throw new InvalidOperationException("Firebase configuration must be a service-account credential.");
        return new(root.GetProperty("project_id").GetString()!, root.GetProperty("client_email").GetString()!,
            root.GetProperty("private_key").GetString()!, root.TryGetProperty("private_key_id", out var key) ? key.GetString() : null);
    }

    private async Task<string> AccessTokenAsync(FirebaseCredentials credentials, CancellationToken ct)
    {
        await _tokenGate.WaitAsync(ct);
        try
        {
            if (_accessToken is not null && _accessTokenExpires > DateTimeOffset.UtcNow.AddMinutes(2)) return _accessToken;
            var now = DateTimeOffset.UtcNow;
            var header = Encode(JsonSerializer.SerializeToUtf8Bytes(new { alg = "RS256", typ = "JWT", kid = credentials.KeyId }));
            var payload = Encode(JsonSerializer.SerializeToUtf8Bytes(new
            {
                iss = credentials.Email,
                scope = "https://www.googleapis.com/auth/firebase.messaging",
                aud = "https://oauth2.googleapis.com/token",
                iat = now.ToUnixTimeSeconds(),
                exp = now.AddHours(1).ToUnixTimeSeconds()
            }));
            var unsigned = header + "." + payload;
            using var key = RSA.Create();
            key.ImportFromPem(credentials.PrivateKey);
            var assertion = unsigned + "." + Encode(key.SignData(Encoding.UTF8.GetBytes(unsigned), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1));
            using var response = await clients.CreateClient().PostAsync("https://oauth2.googleapis.com/token",
                new FormUrlEncodedContent(new Dictionary<string, string>
                {
                    ["grant_type"] = "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    ["assertion"] = assertion
                }), ct);
            if (!response.IsSuccessStatusCode)
                throw new InvalidOperationException("Firebase authorization failed; pending notifications retained.");
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
            _accessToken = json.RootElement.GetProperty("access_token").GetString()
                ?? throw new InvalidOperationException("Firebase authorization did not return an access token.");
            var expires = json.RootElement.TryGetProperty("expires_in", out var seconds) ? Math.Clamp(seconds.GetInt32(), 1, 3600) : 3600;
            _accessTokenExpires = now.AddSeconds(expires);
            return _accessToken;
        }
        finally { _tokenGate.Release(); }
    }

    private static bool Enabled(NotificationPreferences preferences, string category)
        => category switch { "expenses" => preferences.Expenses, "payments" => preferences.Payments, "invites" => preferences.Invites, _ => false };
    private static string Encode(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    private static bool IsUnregistered(string body)
    {
        try
        {
            using var json = JsonDocument.Parse(body);
            return json.RootElement.TryGetProperty("error", out var error) && error.TryGetProperty("details", out var details) &&
                details.ValueKind == JsonValueKind.Array && details.EnumerateArray().Any(x =>
                    x.TryGetProperty("errorCode", out var code) && code.GetString() == "UNREGISTERED");
        }
        catch (JsonException) { return false; }
    }

}
