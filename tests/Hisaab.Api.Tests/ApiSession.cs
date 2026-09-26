using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace Hisaab.Api.Tests;

internal sealed record ApiSession(HttpClient Client, string UserId, string RefreshToken)
{
    public static async Task<ApiSession> Login(ApiFactory factory, string displayName)
    {
        var client = factory.CreateClient();
        var session = await Json(client, HttpMethod.Post, "/v1/auth/dev", new { displayName });
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", session.GetProperty("accessToken").GetString());
        return new(client, session.GetProperty("user").GetProperty("id").GetString()!, session.GetProperty("refreshToken").GetString()!);
    }

    public static async Task<HttpResponseMessage> Send(HttpClient client, HttpMethod method, string path,
        object? body = null, string? key = null, bool includeKey = true)
    {
        using var request = new HttpRequestMessage(method, path);
        if (body is not null) request.Content = JsonContent.Create(body);
        if (includeKey && method != HttpMethod.Get) request.Headers.Add("Idempotency-Key", key ?? Guid.NewGuid().ToString());
        return await client.SendAsync(request);
    }

    public static async Task<JsonElement> Json(HttpClient client, HttpMethod method, string path,
        object? body = null, string? key = null)
    {
        using var response = await Send(client, method, path, body, key);
        var text = await response.Content.ReadAsStringAsync();
        Assert.True(response.IsSuccessStatusCode, $"{method} {path}: {(int)response.StatusCode} {text}");
        return JsonDocument.Parse(text).RootElement.Clone();
    }

    public static async Task<JsonElement> Error(HttpClient client, HttpMethod method, string path,
        HttpStatusCode expected, object? body = null, string? key = null, bool includeKey = true)
    {
        using var response = await Send(client, method, path, body, key, includeKey);
        var text = await response.Content.ReadAsStringAsync();
        Assert.True(response.StatusCode == expected, $"{method} {path}: expected {(int)expected}, got {(int)response.StatusCode} {text}");
        var error = JsonDocument.Parse(text).RootElement.Clone();
        Assert.False(string.IsNullOrWhiteSpace(error.GetProperty("code").GetString()));
        Assert.False(string.IsNullOrWhiteSpace(error.GetProperty("correlationId").GetString()));
        return error;
    }
}
