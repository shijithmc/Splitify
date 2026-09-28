using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.Lambda.AspNetCoreServer.Hosting;
using Hisaab.Api.Billing;
using Hisaab.Api.Contracts;
using Hisaab.Api.Identity;
using Hisaab.Api.Ledger;
using Hisaab.Api.Receipts;
using Hisaab.Api.Receipts.Infrastructure;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
using Hisaab.Infrastructure.Storage;

var builder = WebApplication.CreateBuilder(args);
// Request-start diagnostics include query strings (receipt tickets). Keep transport
// logs at Warning; application failures log only type and correlation identifier.
builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
builder.Logging.AddFilter("System.Net.Http.HttpClient", LogLevel.Warning);
await ConfigurationSecrets.LoadAsync(builder.Configuration);
if (builder.Environment.IsDevelopment() && string.IsNullOrWhiteSpace(builder.Configuration["Hisaab:EncryptionKey"]))
{
    var directory = Path.GetDirectoryName(builder.Configuration["Hisaab:LocalDataPath"] ?? ".local/hisaab.json") ?? ".local";
    Directory.CreateDirectory(directory); var keyPath = Path.Combine(directory, "encryption.key");
    if (!File.Exists(keyPath)) { try { var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write }; if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite; using var file = new FileStream(keyPath, options); using var writer = new StreamWriter(file); writer.Write(Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32))); } catch (IOException) when (File.Exists(keyPath)) { } }
    builder.Configuration["Hisaab:EncryptionKey"] = File.ReadAllText(keyPath);
}
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 2048 * 1024);
builder.Services.ConfigureHttpJsonOptions(options => options.SerializerOptions.Converters.Add(new System.Text.Json.Serialization.JsonStringEnumConverter()));
builder.Services.AddAWSLambdaHosting(LambdaEventSource.HttpApi);
builder.Services.AddHttpClient().ConfigureHttpClientDefaults(options => options.ConfigureHttpClient(client => client.Timeout = TimeSpan.FromSeconds(15)));
builder.Services.AddSingleton<IAtomicStore>(services =>
{
    var config = services.GetRequiredService<IConfiguration>(); var env = services.GetRequiredService<IHostEnvironment>(); var table = config["Hisaab:TableName"];
    if (!string.IsNullOrWhiteSpace(table)) return new DynamoDbAtomicStore(new AmazonDynamoDBClient(), table);
    if (!env.IsDevelopment() && !env.IsEnvironment("Testing")) throw new InvalidOperationException("Hisaab:TableName is required outside Development/Testing.");
    return new LocalAtomicStore(config["Hisaab:LocalDataPath"] ?? Path.Combine(".local", "hisaab.json"));
});
builder.Services.AddSingleton<IProviderVerifier, ProviderVerifier>();
builder.Services.AddSingleton<TokenProtector>(); builder.Services.AddSingleton<AppleTokens>();
builder.Services.AddSingleton<IdentityService>(); builder.Services.AddSingleton<BillingService>();
builder.Services.AddSingleton<CommandExecutor>(); builder.Services.AddSingleton<LedgerApplication>();
builder.Services.AddSingleton<AccountDeletionService>(); builder.Services.AddSingleton<BackgroundJobs>();
builder.Services.AddSingleton<PushService>();
builder.Services.AddSingleton<ReceiptAccess>(); builder.Services.AddSingleton<ReceiptDocuments>();
builder.Services.AddSingleton<ReceiptQuotaService>(); builder.Services.AddSingleton<ReceiptBudgetService>();
builder.Services.AddSingleton<ReceiptAttachmentService>(); builder.Services.AddSingleton<ReceiptService>();
builder.Services.AddSingleton<ReceiptLifecycle>(); builder.Services.AddSingleton<ReceiptWorker>();
builder.Services.AddReceiptInfrastructure(builder.Configuration, builder.Environment);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<DistributedRateLimiter>();
builder.Services.AddSingleton<ApiRateLimits>();
builder.Services.AddOptions<ApiRateLimitOptions>().BindConfiguration("Hisaab:RateLimits")
    .Validate(options => options.IsValid(), "Every API rate limit must be between 1 and 10000 requests per minute.").ValidateOnStart();
var app = builder.Build();
app.UseRouting();
app.Use(async (ctx, next) =>
{
    try { await next(); }
    catch (DomainException ex) { ctx.Response.StatusCode = ex.Status; await ctx.Response.WriteAsJsonAsync(new { code = ex.Code, message = ex.Message, correlationId = ctx.TraceIdentifier }); }
    catch (StoreConflictException) { ctx.Response.StatusCode = 409; await ctx.Response.WriteAsJsonAsync(new { code = "concurrent_change", message = "This record changed. Refresh and try again.", correlationId = ctx.TraceIdentifier }); }
    catch (StoreValidationException) { ctx.Response.StatusCode = 422; await ctx.Response.WriteAsJsonAsync(new { code = "transaction_invalid", message = "This change exceeds a supported limit.", correlationId = ctx.TraceIdentifier }); }
    catch (BadHttpRequestException ex) { ctx.Response.StatusCode = ex.StatusCode; await ctx.Response.WriteAsJsonAsync(new { code = "request_invalid", message = "Check the request fields.", correlationId = ctx.TraceIdentifier }); }
    catch (Exception ex) { app.Logger.LogError("Request failed with {ErrorType}; correlation {CorrelationId}", ex.GetType().Name, ctx.TraceIdentifier); ctx.Response.StatusCode = 500; await ctx.Response.WriteAsJsonAsync(new { code = "server_error", message = "Something went wrong. Please retry.", correlationId = ctx.TraceIdentifier }); }
});
var publicPaths = new HashSet<string>(StringComparer.Ordinal) { "/v1/auth/dev", "/v1/auth/challenge", "/v1/auth/sign-in", "/v1/auth/refresh", "/v1/auth/apple/callback", "/v1/billing/webhook", "/health" };
app.Use(async (ctx, next) =>
{
    var limits = ctx.RequestServices.GetRequiredService<ApiRateLimits>();
    if (!await limits.AdmitIngressAsync(ctx)) return;
    if (!publicPaths.Contains(ctx.Request.Path.Value ?? ""))
    {
        var bearer = ctx.Request.Headers.Authorization.ToString();
        if (!bearer.StartsWith("Bearer ", StringComparison.Ordinal)) throw new DomainException(401, "sign_in_required", "Sign in to continue.");
        ctx.Items["actor"] = await ctx.RequestServices.GetRequiredService<IdentityService>().AuthenticateAsync(bearer[7..], ctx.RequestAborted);
        if (!await limits.AdmitAccountAsync(ctx, (Actor)ctx.Items["actor"]!)) return;
    }
    await next();
});
Actor Current(HttpContext ctx) => (Actor)ctx.Items["actor"]!;
string Key(HttpContext ctx) => ctx.Request.Headers["Idempotency-Key"].ToString();
app.MapGet("/health", () => new { status = "ok", service = "hisaab" });
app.MapPost("/v1/auth/apple/callback", AppleCallback.HandleAsync);
app.MapGet("/v1/auth/challenge", (IdentityService identity, CancellationToken ct) => identity.ChallengeAsync(ct));
app.MapPost("/v1/auth/dev", (DevSignInRequest input, IdentityService identity, CancellationToken ct) => identity.DevAsync(input.DisplayName, ct));
app.MapPost("/v1/auth/sign-in", (SignInRequest input, IdentityService identity, CancellationToken ct) => identity.SignInAsync(input, ct));
app.MapPost("/v1/auth/refresh", (RefreshRequest input, IdentityService identity, CancellationToken ct) => identity.RefreshAsync(input.RefreshToken, ct));
app.MapPost("/v1/auth/link", (HttpContext ctx, SignInRequest input, IdentityService identity, CancellationToken ct) => identity.LinkAsync(Current(ctx), input, ct));
app.MapPost("/v1/auth/sign-out", async (HttpContext ctx, IdentityService identity, CancellationToken ct) => { await identity.SignOutAsync(Current(ctx), ct); return Results.NoContent(); });
app.MapGet("/v1/me", async (HttpContext ctx, BillingService billing, IAtomicStore store, CancellationToken ct) => new { user = Current(ctx).User, entitlement = await billing.GetAsync(Current(ctx).User.Id, ct), preferences = (await store.GetAsync($"USER#{Current(ctx).User.Id}", "PREFS", ct))?.Deserialize<NotificationPreferences>() ?? new() });
app.MapPatch("/v1/me/preferences", (HttpContext ctx, NotificationPreferences input, IAtomicStore store, CommandExecutor commands, CancellationToken ct) => commands.ExecuteAsync(Current(ctx), Key(ctx), "preferences", input, async () => { var pk = $"USER#{Current(ctx).User.Id}"; var row = await store.GetAsync(pk, "PREFS", ct); return new(input, [StoreMutation.Put(StoreRow.Create(pk, "PREFS", (row?.Version ?? 0) + 1, input), row?.Version)]); }, ct));
app.MapDelete("/v1/me", async (HttpContext ctx, AccountDeletionService deletion, CancellationToken ct) => { var input = await ctx.Request.ReadFromJsonAsync<DeleteAccountRequest>(ct) ?? new(); return await deletion.RequestAsync(Current(ctx), input.Confirm, ct); });
app.MapGet("/v1/groups", (HttpContext ctx, LedgerApplication ledger, CancellationToken ct) => ledger.ListGroupsAsync(Current(ctx).User.Id, ct));
app.MapPost("/v1/groups", (HttpContext ctx, CreateGroupRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.CreateGroupAsync(Current(ctx), Key(ctx), input, ct));
app.MapGet("/v1/groups/{id}", (HttpContext ctx, string id, LedgerApplication ledger, CancellationToken ct) => ledger.GetGroupAsync(id, Current(ctx).User.Id, ct));
app.MapPatch("/v1/groups/{id}", (HttpContext ctx, string id, EditGroupRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.EditGroupAsync(Current(ctx), Key(ctx), id, input, ct));
app.MapPost("/v1/groups/{id}/members", (HttpContext ctx, string id, MemberRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.AddMemberAsync(Current(ctx), Key(ctx), id, input, ct));
app.MapPost("/v1/groups/{id}/members/{participantId}/external", (HttpContext ctx, string id, string participantId, MarkExternalRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.MarkExternalAsync(Current(ctx), Key(ctx), id, participantId, input, ct));
app.MapPost("/v1/groups/{id}/invites/revoke", (HttpContext ctx, string id, RevokeInviteRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.RevokeInviteAsync(Current(ctx), Key(ctx), id, input, ct));
app.MapPost("/v1/groups/{id}/invites", (HttpContext ctx, string id, InviteRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.CreateInviteAsync(Current(ctx), Key(ctx), id, input, ct));
app.MapGet("/v1/invites", (HttpContext ctx, LedgerApplication ledger, CancellationToken ct) => ledger.ContactInvitesAsync(Current(ctx), ct));
app.MapPost("/v1/invites/accept", (HttpContext ctx, AcceptInviteRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.AcceptInviteAsync(Current(ctx), Key(ctx), input, ct));
app.MapPost("/v1/groups/{id}/leave", (HttpContext ctx, string id, LeaveRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.LeaveAsync(Current(ctx), Key(ctx), id, input, ct));
app.MapDelete("/v1/groups/{id}", async (HttpContext ctx, string id, LedgerApplication ledger, CancellationToken ct) => { var input = await ctx.Request.ReadFromJsonAsync<VersionRequest>(ct) ?? new(0); return await ledger.DeleteGroupAsync(Current(ctx), Key(ctx), id, input.Version, ct); });
app.MapGet("/v1/groups/{id}/expenses", (HttpContext ctx, string id, string? cursor, LedgerApplication ledger, CancellationToken ct) => ledger.ExpensesAsync(id, Current(ctx).User.Id, cursor, ct));
app.MapGet("/v1/groups/{id}/expenses/{expenseId}", (HttpContext ctx, string id, string expenseId, LedgerApplication ledger, CancellationToken ct) => ledger.ExpenseAsync(id, expenseId, Current(ctx).User.Id, ct));
app.MapPost("/v1/splits/preview", (SplitRequest input) => SplitEngine.Calculate(input.AmountPaise, input.Mode, input.Participants));
app.MapPost("/v1/groups/{id}/expenses", (HttpContext ctx, string id, ExpenseRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.SaveExpenseAsync(Current(ctx), Key(ctx), id, input, false, ct));
app.MapPut("/v1/groups/{id}/expenses/{expenseId}", (HttpContext ctx, string id, string expenseId, ExpenseRequest input, LedgerApplication ledger, CancellationToken ct) => { if (input.Id != expenseId) throw new DomainException(422, "id_mismatch", "Expense ID does not match the URL."); return ledger.SaveExpenseAsync(Current(ctx), Key(ctx), id, input, true, ct); });
app.MapDelete("/v1/groups/{id}/expenses/{expenseId}", async (HttpContext ctx, string id, string expenseId, LedgerApplication ledger, CancellationToken ct) => { var input = await ctx.Request.ReadFromJsonAsync<VersionRequest>(ct) ?? new(0); return await ledger.TransitionExpenseAsync(Current(ctx), Key(ctx), id, expenseId, input.Version, false, ct); });
app.MapPost("/v1/groups/{id}/expenses/{expenseId}/restore", (HttpContext ctx, string id, string expenseId, VersionRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.TransitionExpenseAsync(Current(ctx), Key(ctx), id, expenseId, input.Version, true, ct));
app.MapGet("/v1/groups/{id}/settlements", (HttpContext ctx, string id, LedgerApplication ledger, CancellationToken ct) => ledger.PaymentsAsync(id, Current(ctx).User.Id, ct));
app.MapPost("/v1/groups/{id}/settlements", (HttpContext ctx, string id, SettlementRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.SettleAsync(Current(ctx), Key(ctx), id, input, ct));
app.MapPost("/v1/groups/{id}/settlements/{paymentId}/dispute", (HttpContext ctx, string id, string paymentId, VersionRequest input, LedgerApplication ledger, CancellationToken ct) => ledger.DisputeAsync(Current(ctx), Key(ctx), id, paymentId, input.Version, ct));
app.MapGet("/v1/balances", (HttpContext ctx, LedgerApplication ledger, CancellationToken ct) => ledger.HomeAsync(Current(ctx).User.Id, ct));
app.MapGet("/v1/activity", (HttpContext ctx, LedgerApplication ledger, CancellationToken ct) => ledger.ActivityAsync(Current(ctx).User.Id, null, ct));
app.MapGet("/v1/groups/{id}/activity", (HttpContext ctx, string id, LedgerApplication ledger, CancellationToken ct) => ledger.ActivityAsync(Current(ctx).User.Id, id, ct));
app.MapGet("/v1/billing/entitlement", (HttpContext ctx, BillingService billing, CancellationToken ct) => billing.GetAsync(Current(ctx).User.Id, ct));
app.MapPost("/v1/billing/refresh", (HttpContext ctx, BillingService billing, CancellationToken ct) => billing.RefreshAsync(Current(ctx).User.Id, ct));
app.MapPost("/v1/billing/webhook", async (HttpContext ctx, JsonElement input, BillingService billing, CancellationToken ct) => { await billing.AcceptWebhookAsync(ctx.Request.Headers.Authorization, input, ct); return Results.Accepted(); });
app.MapPost("/v1/devices", (HttpContext ctx, DeviceRequest input, IAtomicStore store, CommandExecutor commands, CancellationToken ct) => commands.ExecuteAsync(Current(ctx), Key(ctx), "device", input, async () =>
{
    if (!Guid.TryParse(input.Id, out _) || string.IsNullOrWhiteSpace(input.Token) || input.Token.Length > 4096 || input.Platform is not ("ios" or "android")) throw new DomainException(422, "device_invalid", "Invalid device registration.");
    var pk = $"USER#{Current(ctx).User.Id}"; var row = await store.GetAsync(pk, $"DEVICE#{input.Id}", ct); var devices = await store.QueryAsync(pk, "DEVICE#", 100, ct: ct);
    if (row is null && devices.Items.Count >= 20) throw new DomainException(422, "device_limit", "Remove an old device before adding another.");
    return new(new { registered = true }, [StoreMutation.Put(StoreRow.Create(pk, $"DEVICE#{input.Id}", (row?.Version ?? 0) + 1, new { input.Id, input.Token, input.Platform, sessionHash = Current(ctx).SessionHash }), row?.Version)]);
}, ct));
app.MapDelete("/v1/devices/{id}", (HttpContext ctx, string id, IAtomicStore store, CommandExecutor commands, CancellationToken ct) => commands.ExecuteAsync(Current(ctx), Key(ctx), $"device:delete:{id}", new { id }, async () => { var row = await store.GetAsync($"USER#{Current(ctx).User.Id}", $"DEVICE#{id}", ct); return new(new { deleted = true }, row is null ? [] : [StoreMutation.Delete(row.Pk, row.Sk, row.Version)]); }, ct));
app.MapReceipts();
app.MapReceiptInfrastructure();
app.Run();
public partial class Program;
