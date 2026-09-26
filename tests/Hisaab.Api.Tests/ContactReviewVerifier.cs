using Hisaab.Api.Identity;

namespace Hisaab.Api.Tests;

internal sealed class ContactReviewVerifier : IProviderVerifier
{
    public Task<VerifiedIdentity> VerifyAsync(SignInRequest request, CancellationToken ct = default) =>
        Task.FromResult(new VerifiedIdentity("google", "unchanged-provider-subject",
            request.IdToken == "before-rename" ? "former@example.org" : "current@example.org", true, "test-client"));
}
