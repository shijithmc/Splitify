namespace Hisaab.Api.Identity;

public sealed record VerifiedIdentity(string Provider, string Subject, string? Email, bool AuthoritativeEmail, string Audience);
