using Hisaab.Application.Storage;

namespace Hisaab.Api.Tests;

internal sealed class CancelAfterMembershipStore(IAtomicStore inner, string userId, CancellationTokenSource interruption) : IAtomicStore
{
    private bool interrupted;

    public Task<StoreRow?> GetAsync(string pk, string sk, CancellationToken ct = default) => inner.GetAsync(pk, sk, ct);
    public Task<StorePage> QueryAsync(string pk, string prefix, int limit = 100, string? cursor = null, CancellationToken ct = default)
        => inner.QueryAsync(pk, prefix, limit, cursor, ct);

    public async Task TransactAsync(IReadOnlyList<StoreMutation> mutations, CancellationToken ct = default)
    {
        await inner.TransactAsync(mutations, ct);
        if (!interrupted && mutations.Any(m => m.Kind == StoreMutationKind.Delete && m.Key.Pk == $"USER#{userId}" && m.Key.Sk.StartsWith("GROUP#", StringComparison.Ordinal)))
        {
            interrupted = true;
            interruption.Cancel();
            throw new OperationCanceledException(interruption.Token);
        }
    }
}
