using System.Text.Json;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptDocuments(IAtomicStore store)
{
    public static IReadOnlyList<StoreMutation> Create(string receiptId, string prefix, object document)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(document, JsonDefaults.Options);
        if (bytes.Length > 1536 * 1024) throw new DomainException(422,"receipt_too_large","The itemised receipt exceeds the supported size.");
        var chunks = bytes.Chunk(64 * 1024).ToArray();
        var writes = new List<StoreMutation> { StoreMutation.Put(StoreRow.Create($"RECEIPT#{receiptId}", prefix, 1, new { pages = chunks.Length }), null) };
        for (var i = 0; i < chunks.Length; i++) writes.Add(StoreMutation.Put(StoreRow.Create($"RECEIPT#{receiptId}", $"{prefix}#PAGE#{i:D2}",1,new { content = Convert.ToBase64String(chunks[i]) }),null));
        return writes;
    }
    public async Task<JsonElement?> ReadAsync(string receiptId, string prefix, CancellationToken ct)
    {
        var header = await store.GetAsync($"RECEIPT#{receiptId}",prefix,ct); if (header is null) return null;
        var pages = header.Data.GetProperty("pages").GetInt32();
        if (pages is < 1 or > 24) throw new InvalidDataException("Invalid receipt pages.");
        using var buffer = new MemoryStream();
        for (var i = 0; i < pages; i++)
        {
            var page = await store.GetAsync(header.Pk,$"{prefix}#PAGE#{i:D2}",ct) ?? throw new InvalidDataException("Missing receipt page.");
            var bytes = Convert.FromBase64String(page.Data.GetProperty("content").GetString()!); if(bytes.Length>64*1024) throw new InvalidDataException("Invalid receipt page size.");
            buffer.Write(bytes);
        }
        using var json = JsonDocument.Parse(buffer.ToArray()); return json.RootElement.Clone();
    }
}
