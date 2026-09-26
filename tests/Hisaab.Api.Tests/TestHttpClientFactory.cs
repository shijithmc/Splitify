namespace Hisaab.Api.Tests;

internal sealed class TestHttpClientFactory(Func<HttpRequestMessage, HttpResponseMessage> respond) : IHttpClientFactory, IDisposable
{
    private readonly HttpClient client = new(new TestHttpMessageHandler(respond));
    public HttpClient CreateClient(string name) => client;
    public void Dispose() => client.Dispose();
}
