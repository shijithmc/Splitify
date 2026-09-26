using Hisaab.Api.Billing;
namespace Hisaab.Api.Identity;

public sealed record SessionResult(string AccessToken, string RefreshToken, UserAccount User, Entitlement Entitlement);
