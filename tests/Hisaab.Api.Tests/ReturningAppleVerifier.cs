using Hisaab.Api.Identity;

namespace Hisaab.Api.Tests;

internal sealed class ReturningAppleVerifier : IProviderVerifier
{
    public List<SignInRequest> Requests { get; } = [];

    public Task<VerifiedIdentity> VerifyAsync(SignInRequest request, CancellationToken ct = default)
    {
        Requests.Add(request);
        return Task.FromResult(new VerifiedIdentity("apple", request.IdToken == "wrong-subject-token" ? "other-account" : "returning-account",
            null, false, "com.hisaab.service"));
    }
}
