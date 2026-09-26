using Hisaab.Api.Receipts.Infrastructure;
namespace Hisaab.Api.Tests;

internal sealed class FixedVertexAccessToken : IVertexAccessToken
{
    public Task<string> GetAsync(CancellationToken ct) => Task.FromResult("test-token");
}
