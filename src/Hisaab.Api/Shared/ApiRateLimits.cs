using System.Globalization;
using System.Net;
using Hisaab.Api.Identity;
using Microsoft.Extensions.Options;

namespace Hisaab.Api.Shared;

public sealed class ApiRateLimitOptions
{
    public int RequestsPerIpPerMinute { get; set; } = 600;
    public int AuthRequestsPerIpPerMinute { get; set; } = 30;
    public int RequestsPerAccountPerMinute { get; set; } = 240;
    public int AuthRequestsPerAccountPerMinute { get; set; } = 30;
    public int ReceiptRequestsPerIpPerMinute { get; set; } = 30;
    public int ReceiptRequestsPerAccountPerMinute { get; set; } = 12;

    public bool IsValid() => new[] { RequestsPerIpPerMinute, AuthRequestsPerIpPerMinute,
        RequestsPerAccountPerMinute, AuthRequestsPerAccountPerMinute,
        ReceiptRequestsPerIpPerMinute, ReceiptRequestsPerAccountPerMinute }.All(value => value is >= 1 and <= 10000);
}

/// <summary>Apply to endpoints that create or submit receipt uploads.</summary>
public sealed class ReceiptWriteRateLimit;

public sealed class ApiRateLimits(DistributedRateLimiter limiter, IOptions<ApiRateLimitOptions> options)
{
    public async Task<bool> AdmitIngressAsync(HttpContext context)
    {
        var policy = options.Value;
        // Lambda's HTTP API v2 adapter fills RemoteIpAddress from requestContext.http.sourceIp.
        // Never accept identity from X-Forwarded-For or a user-supplied account/device header.
        var source = Source(context.Connection.RemoteIpAddress);
        var limits = new List<RequestRateLimit> { new("ip", source, policy.RequestsPerIpPerMinute) };
        if (IsAuth(context)) limits.Add(new("auth-ip", source, policy.AuthRequestsPerIpPerMinute));
        if (IsReceiptWrite(context)) limits.Add(new("receipt-ip", source, policy.ReceiptRequestsPerIpPerMinute));
        return await AdmitAsync(context, limits);
    }

    public async Task<bool> AdmitAccountAsync(HttpContext context, Actor actor)
    {
        var policy = options.Value;
        var limits = new List<RequestRateLimit> { new("account", actor.User.Id, policy.RequestsPerAccountPerMinute) };
        if (IsAuth(context)) limits.Add(new("auth-account", actor.User.Id, policy.AuthRequestsPerAccountPerMinute));
        if (IsReceiptWrite(context)) limits.Add(new("receipt-account", actor.User.Id, policy.ReceiptRequestsPerAccountPerMinute));
        return await AdmitAsync(context, limits);
    }

    private async Task<bool> AdmitAsync(HttpContext context, IReadOnlyList<RequestRateLimit> limits)
    {
        var decision = await limiter.AdmitAsync(limits, context.RequestAborted);
        if (decision.Allowed) return true;
        context.Response.StatusCode = StatusCodes.Status429TooManyRequests;
        context.Response.Headers.RetryAfter = decision.RetryAfterSeconds.ToString(CultureInfo.InvariantCulture);
        context.Response.Headers.CacheControl = "no-store";
        await context.Response.WriteAsJsonAsync(new { code = "rate_limited", message = "Too many requests. Please retry later.",
            correlationId = context.TraceIdentifier }, context.RequestAborted);
        return false;
    }

    private static bool IsAuth(HttpContext context) => context.Request.Path.StartsWithSegments("/v1/auth", StringComparison.OrdinalIgnoreCase);
    private static bool IsReceiptWrite(HttpContext context) => context.GetEndpoint()?.Metadata.GetMetadata<ReceiptWriteRateLimit>() is not null;

    internal static string Source(IPAddress? address)
    {
        if (address is null) return "unknown";
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6)
        {
            var bytes = address.GetAddressBytes();
            Array.Clear(bytes, 8, 8); // Rotating addresses within one IPv6 /64 shares a limit.
            return new IPAddress(bytes) + "/64";
        }
        return address.ToString();
    }
}
