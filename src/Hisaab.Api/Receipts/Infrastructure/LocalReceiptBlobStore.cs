using System.Security.Cryptography;
using System.Text;
using Hisaab.Domain;

namespace Hisaab.Api.Receipts.Infrastructure;

public sealed class LocalReceiptBlobStore(IConfiguration configuration) : IReceiptBlobStore
{
    private readonly string _directory = Path.GetFullPath(configuration["Hisaab:Receipts:LocalPath"] ?? ".local/receipts");
    private byte[] Key => Convert.FromBase64String(configuration["Hisaab:EncryptionKey"] ?? throw new InvalidOperationException("An encryption key is required for receipt storage."));

    public Task<ReceiptUploadGrant> CreateUploadAsync(ReceiptUploadSlot slot, CancellationToken ct = default)
    {
        var ids = ReceiptObjectKeys.ParseUpload(slot.Key);
        return Task.FromResult(new ReceiptUploadGrant(slot.Id, $"/v1/receipts/uploads/{ids.ReceiptId}/{ids.ImageId}", "PUT",
            new Dictionary<string, string> { ["Content-Type"] = slot.ContentType }, DateTimeOffset.UtcNow.AddMinutes(5)));
    }
    public async Task AcceptUploadAsync(ReceiptUploadSlot slot, Stream source, CancellationToken ct = default)
    {
        ReceiptObjectKeys.ParseUpload(slot.Key);
        if (slot.SizeBytes is <= 0 or > ReceiptImageNormalizer.MaxBytes) throw new DomainException(413, "receipt_too_large", "Choose an image under 10 MiB.");
        using var buffer = new MemoryStream();
        var block = new byte[64 * 1024];
        int read;
        while ((read = await source.ReadAsync(block, ct)) > 0)
        {
            if (buffer.Length + read > slot.SizeBytes) throw new DomainException(413, "receipt_too_large", "The upload exceeds its declared size.");
            buffer.Write(block, 0, read);
        }
        var bytes = buffer.ToArray();
        if (bytes.LongLength != slot.SizeBytes || !Convert.ToHexString(SHA256.HashData(bytes)).Equals(slot.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new DomainException(422, "receipt_upload_invalid", "The image did not upload completely.");
        await WriteAsync(slot.Key, bytes, ct);
    }
    public async Task<IReadOnlyList<ReceiptMedia>> ValidateAsync(string receiptId, IReadOnlyList<ReceiptUploadSlot> slots, CancellationToken ct = default)
    {
        var result = new List<ReceiptMedia>();
        foreach (var slot in slots)
        {
            if (ReceiptObjectKeys.ParseUpload(slot.Key).ReceiptId != receiptId) throw new DomainException(404, "receipt_not_found", "Receipt not found.");
            var normalized = ReceiptImageNormalizer.Normalize(await LoadAsync(slot.Key, ct), slot);
            var key = $"images/{receiptId}/{slot.Id}.jpg"; var thumbnail = $"thumbs/{receiptId}/{slot.Id}.jpg";
            await WriteAsync(key, normalized.Image, ct); await WriteAsync(thumbnail, normalized.Thumbnail, ct);
            result.Add(new(slot.Id, key, thumbnail, "image/jpeg", normalized.Image.Length,
                Convert.ToHexString(SHA256.HashData(normalized.Image)).ToLowerInvariant(), normalized.Width, normalized.Height, normalized.Thumbnail.Length));
        }
        return result;
    }
    public async Task<byte[]> ReadAsync(ReceiptMedia media, bool thumbnail, long offset, int length, CancellationToken ct = default)
    {
        var bytes = await LoadAsync(thumbnail ? media.ThumbnailKey : media.Key, ct);
        if (offset < 0 || offset >= bytes.LongLength || length is < 1 or > ReceiptImageNormalizer.MaxBytes)
            throw new DomainException(416, "receipt_range_invalid", "Invalid image range.");
        return bytes.AsSpan((int)offset, Math.Min(length, bytes.Length - (int)offset)).ToArray();
    }
    public Task DeleteAsync(string receiptId, CancellationToken ct = default)
    {
        if (!Guid.TryParseExact(receiptId, "D", out _)) throw new ArgumentException("Invalid receipt ID.", nameof(receiptId));
        foreach (var prefix in new[] { "quarantine", "images", "thumbs" })
        {
            ct.ThrowIfCancellationRequested(); var directory = Path.Combine(_directory, prefix, receiptId);
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
        return Task.CompletedTask;
    }
    private async Task WriteAsync(string key, byte[] bytes, CancellationToken ct)
    {
        var path = Path.Combine(_directory, ReceiptObjectKeys.Validate(key)); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var envelope = new byte[28 + bytes.Length]; RandomNumberGenerator.Fill(envelope.AsSpan(0, 12));
        using (var aes = new AesGcm(Key, 16)) aes.Encrypt(envelope.AsSpan(0, 12), bytes, envelope.AsSpan(28), envelope.AsSpan(12, 16), Encoding.UTF8.GetBytes(key));
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { await File.WriteAllBytesAsync(temporary, envelope, ct); if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private async Task<byte[]> LoadAsync(string key, CancellationToken ct)
    {
        var path = Path.Combine(_directory, ReceiptObjectKeys.Validate(key));
        if (!File.Exists(path)) throw new DomainException(404, "receipt_image_missing", "The image is unavailable. Upload it again.");
        var bytes = await File.ReadAllBytesAsync(path, ct);
        if (bytes.Length < 28 || bytes.Length > ReceiptImageNormalizer.MaxBytes + 28) throw new DomainException(422, "receipt_image_invalid", "The stored image is invalid.");
        var result = new byte[bytes.Length - 28];
        using (var aes = new AesGcm(Key, 16)) aes.Decrypt(bytes.AsSpan(0, 12), bytes.AsSpan(28), bytes.AsSpan(12, 16), result, Encoding.UTF8.GetBytes(key));
        return result;
    }
}
