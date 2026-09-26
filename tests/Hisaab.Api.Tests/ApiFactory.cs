using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hisaab.Api.Tests;

public sealed class ApiFactory(string environment = "Development", bool devAuth = true) : WebApplicationFactory<Program>
{
    public LocalAtomicStore Store { get; } = new(null);
    public Func<HttpRequestMessage, HttpResponseMessage>? ProviderResponse { get; init; }
    public string BillingEnvironment { get; init; } = "PRODUCTION";

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(environment);
        builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Hisaab:DevAuth"] = devAuth.ToString(),
            ["Hisaab:RevenueCat:WebhookAuthorization"] = "Bearer integration-test-webhook-key",
            ["Hisaab:RevenueCat:Environment"] = BillingEnvironment,
            ["Hisaab:RevenueCat:SecretKey"] = ProviderResponse is null ? "" : "test-only-provider-secret",
            ["Hisaab:ContactHashKey"] = "integration-test-contact-key",
            ["Hisaab:EncryptionKey"] = Convert.ToBase64String(new byte[32]),
            ["Hisaab:DynamoDb:TableName"] = "integration-test-unused",
            ["Hisaab:TableName"] = "integration-test-unused"
        }));
        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<IAtomicStore>();
            services.AddSingleton<IAtomicStore>(Store);
            if (ProviderResponse is not null)
            {
                services.RemoveAll<IHttpClientFactory>();
                services.AddSingleton<IHttpClientFactory>(new TestHttpClientFactory(ProviderResponse));
            }
        });
    }
}
