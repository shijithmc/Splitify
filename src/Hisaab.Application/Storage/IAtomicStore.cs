namespace Hisaab.Application.Storage;

public interface IAtomicStore
{
    Task<StoreRow?> GetAsync(string pk, string sk, CancellationToken ct = default);
    Task<StorePage> QueryAsync(string pk, string prefix, int limit = 100, string? cursor = null, CancellationToken ct = default);
    Task TransactAsync(IReadOnlyList<StoreMutation> mutations, CancellationToken ct = default);
}
