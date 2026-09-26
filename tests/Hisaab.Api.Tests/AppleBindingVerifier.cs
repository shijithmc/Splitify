using Hisaab.Api.Identity;

namespace Hisaab.Api.Tests;

internal sealed class AppleBindingVerifier(string subject, string audience) : IProviderVerifier
{
    public SignInRequest? LastRequest { get; private set; }

    public Task<VerifiedIdentity> VerifyAsync(SignInRequest request, CancellationToken ct = default)
    {
        LastRequest = request;
        return Task.FromResult(new VerifiedIdentity("apple", subject, null, false, audience));
    }
}
