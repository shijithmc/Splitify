namespace Hisaab.Api.Identity;

public interface IProviderVerifier { Task<VerifiedIdentity> VerifyAsync(SignInRequest request, CancellationToken ct = default); }
