using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using Amazon.S3;
using Amazon.S3.Model;
using Hisaab.Domain;

namespace Hisaab.Api.Receipts.Infrastructure;

public sealed class S3ReceiptBlobStore(IAmazonS3 s3, IConfiguration configuration) : IReceiptBlobStore
{
    private readonly string _bucket = configuration["Hisaab:Receipts:BucketName"] ?? throw new InvalidOperationException("Receipt bucket is required.");
    public async Task<ReceiptUploadGrant> CreateUploadAsync(ReceiptUploadSlot slot, CancellationToken ct = default)
    {
        ReceiptObjectKeys.ParseUpload(slot.Key);
        if (slot.SizeBytes is <= 0 or > ReceiptImageNormalizer.MaxBytes || slot.Sha256.Length != 64)
            throw new DomainException(422, "receipt_upload_invalid", "Invalid image size or checksum.");
        var checksum = Convert.ToBase64String(Convert.FromHexString(slot.Sha256));
        var expires = DateTimeOffset.UtcNow.AddMinutes(5);
        var request = new GetPreSignedUrlRequest
        {
            BucketName = _bucket, Key = slot.Key, Verb = HttpVerb.PUT,
            Expires = expires.UtcDateTime, Protocol = Protocol.HTTPS, ContentType = slot.ContentType,
            ServerSideEncryptionMethod = ServerSideEncryptionMethod.AES256
        };
        request.Headers["Content-Length"] = slot.SizeBytes.ToString(CultureInfo.InvariantCulture);
        request.Headers["x-amz-checksum-sha256"] = checksum;
        var url = await s3.GetPreSignedURLAsync(request);
        ct.ThrowIfCancellationRequested();
        return new(slot.Id, url, "PUT", new Dictionary<string, string>
        {
            ["Content-Type"] = slot.ContentType, ["Content-Length"] = slot.SizeBytes.ToString(CultureInfo.InvariantCulture),
            ["x-amz-checksum-sha256"] = checksum, ["x-amz-server-side-encryption"] = "AES256"
        }, expires);
    }
    public async Task<IReadOnlyList<ReceiptMedia>> ValidateAsync(string receiptId, IReadOnlyList<ReceiptUploadSlot> slots, CancellationToken ct = default)
    {
        var result = new List<ReceiptMedia>();
        foreach (var slot in slots)
        {
            if (ReceiptObjectKeys.ParseUpload(slot.Key).ReceiptId != receiptId) throw new DomainException(404, "receipt_not_found", "Receipt not found.");
            using var response = await GetAsync(new GetObjectRequest { BucketName = _bucket, Key = slot.Key }, ct);
            if (response.ContentLength != slot.SizeBytes || response.Headers.ContentType != slot.ContentType)
                throw new DomainException(422, "receipt_upload_invalid", "The uploaded image does not match its manifest.");
            var bytes = await ReadBoundedAsync(response.ResponseStream, ReceiptImageNormalizer.MaxBytes, ct);
            var normalized = ReceiptImageNormalizer.Normalize(bytes, slot);
            var key = $"images/{receiptId}/{slot.Id}.jpg"; var thumb = $"thumbs/{receiptId}/{slot.Id}.jpg";
            await PutAsync(key, normalized.Image, ct); await PutAsync(thumb, normalized.Thumbnail, ct);
            result.Add(new(slot.Id, key, thumb, "image/jpeg", normalized.Image.Length, Convert.ToHexString(SHA256.HashData(normalized.Image)).ToLowerInvariant(),
                normalized.Width, normalized.Height, normalized.Thumbnail.Length));
        }
        return result;
    }
    public async Task<byte[]> ReadAsync(ReceiptMedia media, bool thumbnail, long offset, int length, CancellationToken ct = default)
    {
        var size = thumbnail ? media.ThumbnailSizeBytes : media.SizeBytes;
        if (offset < 0 || offset >= size || length is < 1 or > ReceiptImageNormalizer.MaxBytes)
            throw new DomainException(416, "receipt_range_invalid", "Invalid image range.");
        var key = ReceiptObjectKeys.Validate(thumbnail ? media.ThumbnailKey : media.Key);
        using var response = await GetAsync(new GetObjectRequest { BucketName = _bucket, Key = key, ByteRange = new ByteRange(offset, Math.Min(size - 1, checked(offset + length - 1))) }, ct);
        return await ReadBoundedAsync(response.ResponseStream, length, ct);
    }
    public async Task DeleteAsync(string receiptId, CancellationToken ct = default)
    {
        if (!Guid.TryParseExact(receiptId, "D", out _)) throw new ArgumentException("Invalid receipt ID.", nameof(receiptId));
        foreach (var prefix in new[] { "quarantine", "images", "thumbs" })
        {
            // ListVersions includes delete markers as S3ObjectVersion entries. Purge every version,
            // including "null" in an unversioned bucket; a delete marker alone is not erasure.
            string? keyMarker = null; string? versionMarker = null;
            do
            {
                var page = await s3.ListVersionsAsync(new ListVersionsRequest { BucketName = _bucket, Prefix = $"{prefix}/{receiptId}/", KeyMarker = keyMarker, VersionIdMarker = versionMarker, MaxKeys = 100 }, ct);
                foreach (var version in page.Versions ?? [])
                    await s3.DeleteObjectAsync(new DeleteObjectRequest { BucketName = _bucket, Key = version.Key, VersionId = version.VersionId }, ct);
                keyMarker = page.IsTruncated == true ? page.NextKeyMarker : null;
                versionMarker = page.IsTruncated == true ? page.NextVersionIdMarker : null;
            } while (keyMarker is not null);
        }
    }
    private async Task PutAsync(string key, byte[] bytes, CancellationToken ct)
    {
        using var stream = new MemoryStream(bytes, false);
        await s3.PutObjectAsync(new PutObjectRequest { BucketName = _bucket, Key = ReceiptObjectKeys.Validate(key), InputStream = stream,
            ContentType = "image/jpeg", ServerSideEncryptionMethod = ServerSideEncryptionMethod.AES256, ChecksumSHA256 = Convert.ToBase64String(SHA256.HashData(bytes)) }, ct);
    }
    private async Task<GetObjectResponse> GetAsync(GetObjectRequest request, CancellationToken ct)
    {
        try { return await s3.GetObjectAsync(request, ct); }
        catch (AmazonS3Exception ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        { throw new DomainException(404, "receipt_image_missing", "The image is unavailable. Upload it again."); }
    }
    internal static async Task<byte[]> ReadBoundedAsync(Stream stream, int maximum, CancellationToken ct)
    {
        using var output = new MemoryStream(); var block = new byte[64 * 1024]; int read;
        while ((read = await stream.ReadAsync(block, ct)) > 0)
        {
            if (output.Length + read > maximum) throw new DomainException(413, "receipt_too_large", "The receipt exceeds the supported size.");
            output.Write(block, 0, read);
        }
        return output.ToArray();
    }
}
