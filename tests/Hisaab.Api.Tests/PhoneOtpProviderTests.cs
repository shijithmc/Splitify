using System.Net;
using System.Net.Http.Json;
using Hisaab.Api.Identity;
using Hisaab.Domain;
using Microsoft.Extensions.Configuration;

namespace Hisaab.Api.Tests;

public sealed class PhoneOtpProviderTests
{
    private const string Phone = "+919876543210";
    private static readonly string ServiceSid = "VA" + new string('a', 32);
    private static readonly string VerificationSid = "VE" + new string('b', 32);
    private static IConfiguration Configuration() => new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> {
        ["Hisaab:Auth:Phone:Enabled"] = "true", ["Hisaab:Auth:Phone:ServiceSid"] = ServiceSid,
        ["Hisaab:Auth:Phone:ApiKeySid"] = "SK" + new string('c', 32), ["Hisaab:Auth:Phone:ApiKeySecret"] = "test-only-secret"
    }).Build();

    [Fact]
    public async Task SendsSmsAndChecksTheProviderVerificationSidOverAuthenticatedHttps()
    {
        using var clients = new TestHttpClientFactory(request => {
            Assert.Equal("https", request.RequestUri!.Scheme); Assert.Equal("verify.twilio.com", request.RequestUri.Host);
            Assert.Equal("Basic", request.Headers.Authorization!.Scheme);
            var checking = request.RequestUri.AbsolutePath.EndsWith("VerificationCheck", StringComparison.Ordinal);
            var body = request.Content!.ReadAsStringAsync().GetAwaiter().GetResult();
            Assert.Contains(checking ? "VerificationSid=" + VerificationSid : "To=%2B919876543210", body);
            Assert.Contains(checking ? "Code=123456" : "Channel=sms", body);
            return new(HttpStatusCode.OK) { Content = JsonContent.Create(new { sid = VerificationSid, service_sid = ServiceSid, to = Phone, channel = "sms", status = checking ? "approved" : "pending" }) };
        });
        var provider = new PhoneOtpProvider(Configuration(), clients);
        Assert.Equal(VerificationSid, await provider.SendAsync(Phone, default));
        Assert.True(await provider.CheckAsync(VerificationSid, Phone, "123456", default));
    }

    [Theory]
    [InlineData("pending", false, false, false, false)]
    [InlineData("approved", true, false, false, false)]
    [InlineData("approved", false, true, false, false)]
    [InlineData("approved", false, false, true, false)]
    [InlineData("approved", false, false, false, true)]
    public async Task NeverAcceptsPendingOrMismatchedProviderEvidence(string status, bool wrongPhone, bool wrongSid, bool wrongService, bool wrongChannel)
    {
        using var clients = new TestHttpClientFactory(_ => new(HttpStatusCode.OK) { Content = JsonContent.Create(new {
            status, sid = wrongSid ? "VEwrong" : VerificationSid, service_sid = wrongService ? "VAwrong" : ServiceSid,
            to = wrongPhone ? "+14155552671" : Phone, channel = wrongChannel ? "email" : "sms"
        }) });
        Assert.False(await new PhoneOtpProvider(Configuration(), clients).CheckAsync(VerificationSid, Phone, "123456", default));
    }

    [Fact]
    public async Task ProviderErrorsDoNotLeakPhoneNumbersCredentialsOrRawResponse()
    {
        using var clients = new TestHttpClientFactory(_ => new(HttpStatusCode.BadGateway) { Content = new StringContent($"secret provider error {Phone} test-only-secret") });
        var error = await Assert.ThrowsAsync<DomainException>(() => new PhoneOtpProvider(Configuration(), clients).SendAsync(Phone, default));
        Assert.Equal(503, error.Status); Assert.Equal("phone_unavailable", error.Code);
        Assert.DoesNotContain(Phone, error.Message); Assert.DoesNotContain("test-only-secret", error.Message);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{}")]
    [InlineData("{\"status\":\"approved\"}")]
    public async Task MalformedOrUnexpectedSendResponsesFailClosed(string body)
    {
        using var clients = new TestHttpClientFactory(_ => new(HttpStatusCode.OK) { Content = new StringContent(body) });
        var error = await Assert.ThrowsAsync<DomainException>(() => new PhoneOtpProvider(Configuration(), clients).SendAsync(Phone, default));
        Assert.Equal("phone_unavailable", error.Code);
    }

    [Fact]
    public async Task ProviderTimeoutIsSanitizedAndExpiredVerificationIsRejected()
    {
        using var timeout = new TestHttpClientFactory(_ => throw new TaskCanceledException("provider secret"));
        var error = await Assert.ThrowsAsync<DomainException>(() => new PhoneOtpProvider(Configuration(), timeout).SendAsync(Phone, default));
        Assert.Equal("phone_unavailable", error.Code); Assert.DoesNotContain("provider secret", error.Message);
        using var expired = new TestHttpClientFactory(_ => new(HttpStatusCode.NotFound));
        Assert.False(await new PhoneOtpProvider(Configuration(), expired).CheckAsync(VerificationSid, Phone, "123456", default));
    }
}
