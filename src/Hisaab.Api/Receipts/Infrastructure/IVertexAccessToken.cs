namespace Hisaab.Api.Receipts.Infrastructure;

public interface IVertexAccessToken
{
    Task<string> GetAsync(CancellationToken ct);
}
