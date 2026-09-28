using System.Security.Cryptography;
using System.Text;
using Amazon;
using Amazon.Runtime;
using Amazon.S3;
using Hisaab.Api.Receipts;
using Hisaab.Api.Receipts.Infrastructure;
using Hisaab.Domain;
using Microsoft.Extensions.Configuration;
using SkiaSharp;

namespace Hisaab.Api.Tests;

public sealed class ReceiptAdapterTests
{
    [Fact]
    public async Task LocalMediaIsEncryptedValidatedStrippedAndPurged()
    {
        var directory = Path.Combine(Path.GetTempPath(), "receipt-adapter-" + Guid.NewGuid());
        try
        {
            var store = new LocalReceiptBlobStore(Config(directory)); var id = Guid.NewGuid().ToString(); var imageId = Guid.NewGuid().ToString();
            var jpg = Image(); var metadata = Encoding.ASCII.GetBytes("Exif\0\0SECRET-GPS");
            var bytes = jpg[..2].Concat(new byte[] { 0xff, 0xe1, 0, (byte)(metadata.Length + 2) }).Concat(metadata).Concat(jpg[2..]).ToArray();
            var slot = Slot(id, imageId, bytes);
            await store.AcceptUploadAsync(slot, new MemoryStream(bytes));
            var disk = await File.ReadAllBytesAsync(Path.Combine(directory, slot.Key));
            Assert.False(disk.AsSpan().SequenceEqual(bytes));
            var media = Assert.Single(await store.ValidateAsync(id, [slot]));
            var normalized = await store.ReadAsync(media, false, 0, (int)media.SizeBytes);
            Assert.DoesNotContain("SECRET-GPS", Encoding.ASCII.GetString(normalized));
            Assert.Equal(64, media.Width); Assert.Equal(96, media.Height);
            Assert.NotEmpty(await store.ReadAsync(media, true, 0, (int)media.ThumbnailSizeBytes));
            await store.DeleteAsync(id); await store.DeleteAsync(id);
            await Assert.ThrowsAsync<DomainException>(() => store.ReadAsync(media, false, 0, 10));
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    [Fact]
    public void ImageValidationRejectsMimeSpoofingOversizedPixelsAndWrongChecksum()
    {
        var id = Guid.NewGuid().ToString(); var img = Guid.NewGuid().ToString(); var bytes = Image();
        Assert.Throws<DomainException>(() => ReceiptImageNormalizer.Normalize(bytes, Slot(id, img, bytes) with { ContentType = "image/png" }));
        Assert.Throws<DomainException>(() => ReceiptImageNormalizer.Normalize(bytes, Slot(id, img, bytes) with { Sha256 = new string('0', 64) }));
        var large = Image(2049, 2);
        Assert.Throws<DomainException>(() => ReceiptImageNormalizer.Normalize(large, Slot(id, img, large)));
        Assert.Throws<DomainException>(() => ReceiptObjectKeys.Validate("images/../../secret"));
    }
    [Fact]
    public async Task PresignedUploadBindsChecksumTypeLengthEncryptionAndShortExpiry()
    {
        using var s3 = new AmazonS3Client(new BasicAWSCredentials("test-access", "test-secret"), RegionEndpoint.APSouth1);
        var store = new S3ReceiptBlobStore(s3, new ConfigurationManager { ["Hisaab:Receipts:BucketName"] = "test-receipt-bucket" });
        var bytes = Image(); var grant = await store.CreateUploadAsync(Slot(Guid.NewGuid().ToString(), Guid.NewGuid().ToString(), bytes));
        var url = Uri.UnescapeDataString(grant.Url);
        Assert.Contains("content-length", url, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("x-amz-checksum-sha256", url, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("AES256", grant.Headers["x-amz-server-side-encryption"]);
        Assert.True(grant.ExpiresAt <= DateTimeOffset.UtcNow.AddMinutes(5));
    }
    private static ConfigurationManager Config(string directory) => new()
    {
        ["Hisaab:Receipts:LocalPath"] = directory, ["Hisaab:EncryptionKey"] = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
    };
    private static ReceiptUploadSlot Slot(string id, string image, byte[] bytes) => new(image, $"quarantine/{id}/{image}", "image/jpeg", bytes.Length, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
    private static byte[] Image(int width = 64, int height = 96)
    {
        using var bitmap = new SKBitmap(width, height); using var canvas = new SKCanvas(bitmap); canvas.Clear(SKColors.White);
        using var image = SKImage.FromBitmap(bitmap); using var data = image.Encode(SKEncodedImageFormat.Jpeg, 85); return data.ToArray();
    }
}
