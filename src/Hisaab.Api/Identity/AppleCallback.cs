using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Identity;

public static class AppleCallback
{
    public static async Task<IResult> HandleAsync(HttpContext context, IAtomicStore store, IConfiguration configuration, CancellationToken ct)
    {
        var package = configuration["Hisaab:Auth:apple:AndroidPackage"];
        if (string.IsNullOrWhiteSpace(package) || package.Length > 200 || !System.Text.RegularExpressions.Regex.IsMatch(package, "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$"))
            throw new DomainException(503, "apple_android_unconfigured", "Apple sign-in on Android is not configured.");
        if (!context.Request.HasFormContentType) throw new DomainException(400, "callback_invalid", "Invalid Apple callback.");
        var form = await context.Request.ReadFormAsync(ct); var state = form["state"].ToString();
        if (state.Length != 64) throw new DomainException(400, "callback_state_invalid", "Start Apple sign-in again.");
        var challenge = await store.GetAsync($"CHALLENGE#{Ids.Hash(state)}", "META", ct);
        if (challenge is null || challenge.Deserialize<ChallengeRecord>().ExpiresAt <= DateTimeOffset.UtcNow)
            throw new DomainException(400, "callback_state_invalid", "Start Apple sign-in again.");
        var fields = new List<string>();
        foreach (var key in new[] { "state", "code", "id_token", "error", "error_description" })
        {
            var value = form[key].ToString(); if (value.Length > 16000) throw new DomainException(400, "callback_invalid", "Invalid Apple callback.");
            if (value.Length > 0) fields.Add($"{key}={Uri.EscapeDataString(value)}");
        }
        context.Response.Headers.CacheControl = "no-store";
        context.Response.Headers["Referrer-Policy"] = "no-referrer";
        return Results.Redirect($"intent://callback?{string.Join('&', fields)}#Intent;package={package};scheme=signinwithapple;end");
    }
}
