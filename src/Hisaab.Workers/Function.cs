using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.Lambda.Core;
using Hisaab.Api.Billing;
using Hisaab.Api.Identity;
using Hisaab.Api.Ledger;
using Hisaab.Api.Shared;
using Hisaab.Api.Receipts;
using Hisaab.Api.Receipts.Infrastructure;
using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

[assembly: LambdaSerializer(typeof(Amazon.Lambda.Serialization.SystemTextJson.DefaultLambdaJsonSerializer))]

namespace Hisaab.Workers;

public sealed class Function
{
    private static readonly object HostGate = new();
    private static Task<IHost>? _host;

    public async Task HandleAsync(JsonElement input, ILambdaContext context)
    {
        var host = await GetHostAsync();
        var remaining = context.RemainingTime - TimeSpan.FromSeconds(5);
        if (remaining <= TimeSpan.Zero) throw new TimeoutException("Insufficient time to safely process background work.");
        using var budget = new CancellationTokenSource(remaining < TimeSpan.FromSeconds(45) ? remaining : TimeSpan.FromSeconds(45));
        var job = input.ValueKind == JsonValueKind.Object && input.TryGetProperty("job", out var value) ? value.GetString() : null;
        // SQS and stream records are wakeups. The durable table rows are the work source of truth.
        // Any failed job throws, causing whole-batch retry; completed rows/delivery markers deduplicate replay.
        await host.Services.GetRequiredService<BackgroundJobs>().RunAsync(job, budget.Token);
    }

    internal static async Task<IHost> GetHostAsync()
    {
        Task<IHost> pending;
        lock (HostGate) pending = _host ??= CreateHostAsync();
        try { return await pending; }
        catch
        {
            // A temporary Secrets Manager outage must not permanently poison a warm worker.
            lock (HostGate) { if (ReferenceEquals(_host, pending)) _host = null; }
            throw;
        }
    }

    internal static async Task<IHost> CreateHostAsync(HostApplicationBuilder? builder = null)
    {
        builder ??= Microsoft.Extensions.Hosting.Host.CreateApplicationBuilder();
        await ConfigurationSecrets.LoadAsync(builder.Configuration);
        builder.Services.AddHttpClient().ConfigureHttpClientDefaults(options =>
            options.ConfigureHttpClient(client => client.Timeout = TimeSpan.FromSeconds(15)));
        builder.Services.AddHttpClient("phone-otp", client => client.Timeout = TimeSpan.FromSeconds(8));
        builder.Services.AddSingleton<IAtomicStore>(_ =>
        {
            var table = builder.Configuration["Hisaab:TableName"];
            if (!string.IsNullOrWhiteSpace(table)) return new DynamoDbAtomicStore(new AmazonDynamoDBClient(), table);
            if (!builder.Environment.IsDevelopment() && !builder.Environment.IsEnvironment("Testing"))
                throw new InvalidOperationException("Hisaab:TableName is required for hosted workers.");
            return new LocalAtomicStore(builder.Configuration["Hisaab:LocalDataPath"] ?? Path.Combine(".local", "hisaab.json"));
        });
        builder.Services.AddSingleton<IProviderVerifier, ProviderVerifier>();
        builder.Services.AddSingleton<IPhoneOtpProvider, PhoneOtpProvider>();
        builder.Services.AddSingleton<PhoneOtpService>();
        builder.Services.AddSingleton<DistributedRateLimiter>();
        builder.Services.AddSingleton(TimeProvider.System);
        builder.Services.AddSingleton<TokenProtector>();
        builder.Services.AddSingleton<AppleTokens>();
        builder.Services.AddSingleton<IdentityService>();
        builder.Services.AddSingleton<BillingService>();
        builder.Services.AddSingleton<CommandExecutor>();
        builder.Services.AddSingleton<LedgerApplication>();
        builder.Services.AddSingleton<AccountDeletionService>();
        builder.Services.AddSingleton<PushService>();
        builder.Services.AddSingleton<BackgroundJobs>();
        builder.Services.AddReceiptInfrastructure(builder.Configuration, builder.Environment);
        builder.Services.AddSingleton<ReceiptAccess>();
        builder.Services.AddSingleton<ReceiptDocuments>();
        builder.Services.AddSingleton<ReceiptQuotaService>();
        builder.Services.AddSingleton<ReceiptLifecycle>();
        builder.Services.AddSingleton<ReceiptAttachmentService>();
        builder.Services.AddSingleton<ReceiptService>();
        builder.Services.AddSingleton<ReceiptWorker>();
        return builder.Build();
    }
}
