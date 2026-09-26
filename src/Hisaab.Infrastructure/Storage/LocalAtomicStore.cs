using System.Collections.Concurrent;
using System.Text.Json;
using Hisaab.Application.Storage;

namespace Hisaab.Infrastructure.Storage;

/// <summary>Single-process local development store; use DynamoDB for hosted or multi-process deployments.</summary>
public sealed class LocalAtomicStore : IAtomicStore
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> FileLocks = new(StringComparer.Ordinal);
    private readonly string? _filePath;
    private readonly SemaphoreSlim _gate;
    private Dictionary<StoreKey, StoreRow> _memoryRows = [];

    public LocalAtomicStore(string? filePath = null)
    {
        _filePath = filePath is null ? null : Path.GetFullPath(filePath);
        _gate = _filePath is null ? new(1, 1) : FileLocks.GetOrAdd(_filePath, _ => new(1, 1));
    }

    public async Task<StoreRow?> GetAsync(string pk, string sk, CancellationToken ct = default)
    {
        StoreValidation.Key(pk, sk);
        await _gate.WaitAsync(ct);
        try { return (await ReadAsync(ct)).GetValueOrDefault(new(pk, sk)); }
        finally { _gate.Release(); }
    }

    public async Task<StorePage> QueryAsync(string pk, string prefix, int limit = 100, string? cursor = null, CancellationToken ct = default)
    {
        StoreValidation.Query(pk, prefix, limit);
        var lastSk = StoreCursor.Decode(cursor, pk, prefix);
        await _gate.WaitAsync(ct);
        try
        {
            var candidates = (await ReadAsync(ct)).Values
                .Where(r => r.Pk == pk && r.Sk.StartsWith(prefix, StringComparison.Ordinal) &&
                    (lastSk is null || string.CompareOrdinal(r.Sk, lastSk) > 0))
                .OrderBy(r => r.Sk, StringComparer.Ordinal).Take(limit + 1).ToArray();
            return new(candidates.Take(limit).ToArray(), candidates.Length > limit
                ? StoreCursor.Encode(pk, prefix, candidates[limit - 1].Sk) : null);
        }
        finally { _gate.Release(); }
    }

    public async Task TransactAsync(IReadOnlyList<StoreMutation> mutations, CancellationToken ct = default)
    {
        StoreValidation.Transaction(mutations);
        await _gate.WaitAsync(ct);
        try
        {
            var rows = await ReadAsync(ct);
            long bytes = 0;
            foreach (var mutation in mutations)
            {
                var current = rows.GetValueOrDefault(mutation.Key);
                if (current?.Version != mutation.ExpectedVersion) throw new StoreConflictException();
                bytes += Math.Max(current is null ? 0 : StoreValidation.ItemBytes(current),
                    mutation.Row is null ? 0 : StoreValidation.ItemBytes(mutation.Row));
            }
            StoreValidation.TransactionBytes(bytes);
            var updated = new Dictionary<StoreKey, StoreRow>(rows);
            foreach (var mutation in mutations)
            {
                if (mutation.Kind == StoreMutationKind.Put)
                    updated[mutation.Key] = mutation.Row! with { Data = mutation.Row!.Data.Clone() };
                else if (mutation.Kind == StoreMutationKind.Delete)
                    updated.Remove(mutation.Key);
            }
            ct.ThrowIfCancellationRequested();
            await SaveAsync(updated, ct);
        }
        finally { _gate.Release(); }
    }

    private async Task<Dictionary<StoreKey, StoreRow>> ReadAsync(CancellationToken ct)
    {
        if (_filePath is null) return _memoryRows;
        if (!File.Exists(_filePath)) return [];
        await using var stream = File.OpenRead(_filePath);
        var rows = await JsonSerializer.DeserializeAsync<StoreRow[]>(stream, cancellationToken: ct)
            ?? throw new InvalidDataException("Local store is invalid; refusing to overwrite it.");
        return rows.ToDictionary(row => new StoreKey(row.Pk, row.Sk));
    }

    private async Task SaveAsync(Dictionary<StoreKey, StoreRow> rows, CancellationToken ct)
    {
        if (_filePath is null) { _memoryRows = rows; return; }
        Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
        var temporary = _filePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            await using (var stream = new FileStream(temporary, options))
            {
                await JsonSerializer.SerializeAsync(stream, rows.Values.ToArray(), cancellationToken: ct);
                await stream.FlushAsync(ct);
                stream.Flush(flushToDisk: true);
            }
            ct.ThrowIfCancellationRequested();
            File.Move(temporary, _filePath, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
