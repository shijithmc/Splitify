using Hisaab.Api.Identity;
using Hisaab.Api.Ledger;
using Hisaab.Api.Receipts;
using Hisaab.Api.Shared;
using Hisaab.Workers;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace Hisaab.Api.Tests;

public sealed class WorkerCompositionTests
{
    [Fact]
    public async Task WorkerResolvesDeletionLedgerAndReceiptJobsWithPhoneAuthDisabled()
    {
        var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings { EnvironmentName = "Testing" });
        builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?> {
            ["Hisaab:SecretsArn"] = "", ["Hisaab:TableName"] = "", ["Hisaab:Auth:Phone:Enabled"] = "false",
            ["Hisaab:LocalDataPath"] = Path.Combine(Path.GetTempPath(), $"worker-composition-{Guid.NewGuid():N}.json")
        });
        using var host = await Function.CreateHostAsync(builder);
        Assert.NotNull(host.Services.GetRequiredService<AccountDeletionService>());
        Assert.NotNull(host.Services.GetRequiredService<LedgerApplication>());
        Assert.NotNull(host.Services.GetRequiredService<BackgroundJobs>());
        Assert.NotNull(host.Services.GetRequiredService<ReceiptWorker>());
        Assert.Equal(TimeSpan.FromSeconds(8), host.Services.GetRequiredService<IHttpClientFactory>().CreateClient("phone-otp").Timeout);
    }
}
