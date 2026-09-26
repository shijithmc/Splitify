namespace Hisaab.Api.Identity;

public sealed record SignInRequest(string Provider, string IdToken, string Nonce, string? AuthorizationCode = null, string? DisplayName = null);
