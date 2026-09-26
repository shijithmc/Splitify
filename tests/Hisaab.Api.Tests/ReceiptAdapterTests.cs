using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Amazon;
using Amazon.Runtime;
using Amazon.S3;
using Google.Apis.Auth.OAuth2;
using Hisaab.Api.Receipts;
using Hisaab.Api.Receipts.Infrastructure;
using Hisaab.Domain;
using Microsoft.Extensions.Configuration;
using SkiaSharp;

namespace Hisaab.Api.Tests;

public sealed class ReceiptAdapterTests
{
    private const string Bill = """
        {"classification":"bill","warnings":[],"document":{"merchant":"किराना","date":"2026-09-26","currency":"INR","subtotal":"100.00","grandTotal":"105.00","merchantConfidence":0.9,"dateConfidence":0.9,"totalConfidence":0.9,"items":[{"name":"Rice","quantity":"1","unitPrice":"100.00","lineTotal":"100.00","transliteration":null,"confidence":0.8}],"charges":[{"name":"CGST","kind":"Tax","amount":"5.00","included":false,"confidence":0.9}]}}
        """;

    [Fact]
    public void ParserKeepsScriptUsesIntegerPaiseAndNeverAssignsPeople()
    {
        var reading = ReceiptExtractionParser.Parse(Bill, "gemini-3.5-flash");
        Assert.Equal("bill", reading.Classification);
        var doc = reading.Document!.Value;
        Assert.Equal("किराना", doc.GetProperty("merchant").GetString());
        Assert.Equal(10500, doc.GetProperty("grandTotalPaise").GetInt64());
        Assert.Empty(doc.GetProperty("items")[0].GetProperty("assigneeIds").EnumerateArray());
        Assert.False(doc.GetProperty("splitByItems").GetBoolean());
    }
    [Theory]
    [InlineData("\"classification\":\"bill\"", "\"execute\":\"send money\",\"classification\":\"bill\"")]
    [InlineData("\"name\":\"Rice\"", "\"name\":\"Rice\",\"tool\":\"delete expense\"")]
    [InlineData("\"grandTotal\":\"105.00\"", "\"grandTotal\":\"105.001\"")]
    [InlineData("\"confidence\":0.8", "\"confidence\":1.8")]
    [InlineData("\"currency\":\"INR\"", "\"currency\":\"INR\",\"currency\":\"USD\"")]
    public void ParserRejectsExtraFieldsDuplicatePropertiesAndMalformedValues(string from, string to)
    {
        Assert.Throws<ReceiptProviderException>(() => ReceiptExtractionParser.Parse(Bill.Replace(from, to), "model"));
    }
    [Fact]
    public void NonBillMissingTotalAndForeignCurrencyCannotCreateAnInrReading()
    {
        var rejected = ReceiptExtractionParser.Parse("{\"classification\":\"not_bill\",\"warnings\":[],\"document\":null}", "model");
        Assert.Null(rejected.Document);
        var missing = ReceiptExtractionParser.Parse(Bill.Replace("\"grandTotal\":\"105.00\"", "\"grandTotal\":null"), "model");
        Assert.Equal("unreadable", missing.Classification);
        var foreign = ReceiptExtractionParser.Parse(Bill.Replace("\"INR\"", "\"KWD\"").Replace("\"105.00\"", "\"105.123\""), "model");
        Assert.Equal(0, foreign.Document!.Value.GetProperty("grandTotalPaise").GetInt64());
        Assert.Equal("105.123", foreign.Document.Value.GetProperty("sourceGrandTotal").GetString());
        Assert.Contains("manual_inr_conversion_required", foreign.Warnings);
    }
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
    [Fact]
    public void FederationConfigurationOnlyCreatesAwsKeylessCredentials()
    {
        var cfg = new ConfigurationManager
        {
            ["Hisaab:Receipts:WorkloadIdentityAudience"] = "//iam.googleapis.com/projects/123456/locations/global/workloadIdentityPools/hisaab/providers/aws",
            ["Hisaab:Receipts:ServiceAccountEmail"] = "receipts@hisaab-test.iam.gserviceaccount.com"
        };
        Assert.IsType<AwsExternalAccountCredential>(WorkloadIdentityToken.Create(cfg).UnderlyingCredential);
        cfg["Hisaab:Receipts:ServiceAccountEmail"] = "bad@outside.test/path";
        Assert.Throws<ReceiptProviderException>(() => WorkloadIdentityToken.Create(cfg));
    }
    [Fact]
    public async Task VertexRequestUsesMumbaiSchemaNoToolsAndNeverFollowsReceiptText()
    {
        var directory = Path.Combine(Path.GetTempPath(), "receipt-vertex-" + Guid.NewGuid());
        try
        {
            var config = Config(directory); var blobs = new LocalReceiptBlobStore(config); var id = Guid.NewGuid().ToString(); var slot = Slot(id, Guid.NewGuid().ToString(), Image());
            await blobs.AcceptUploadAsync(slot, new MemoryStream(Image())); var media = await blobs.ValidateAsync(id, [slot]);
            var calls = 0;
            using var clients = new TestHttpClientFactory(request =>
            {
                calls++; Assert.Equal("asia-south1-aiplatform.googleapis.com", request.RequestUri!.Host);
                Assert.Equal("Bearer", request.Headers.Authorization!.Scheme);
                using var payload = JsonDocument.Parse(request.Content!.ReadAsStringAsync().GetAwaiter().GetResult());
                Assert.False(payload.RootElement.TryGetProperty("tools", out _));
                Assert.True(payload.RootElement.GetProperty("generationConfig").TryGetProperty("responseSchema", out _));
                return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { candidates = new[] { new { finishReason = "STOP", content = new { parts = new[] { new { text = Bill } } } } } })) };
            });
            var extractor = new VertexReceiptExtractor(blobs, new FixedVertexAccessToken(), clients, config);
            Assert.Equal("bill", (await extractor.ExtractAsync(media)).Classification); Assert.Equal(1, calls);
            config["Hisaab:Receipts:VertexRegion"] = "global";
            await Assert.ThrowsAsync<ReceiptProviderException>(() => extractor.ExtractAsync(media)); Assert.Equal(1, calls);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    private static ConfigurationManager Config(string directory) => new()
    {
        ["Hisaab:Receipts:LocalPath"] = directory, ["Hisaab:EncryptionKey"] = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)),
        ["Hisaab:Receipts:VertexProject"] = "hisaab-test", ["Hisaab:Receipts:ProviderValidated"] = "true"
    };
    private static ReceiptUploadSlot Slot(string id, string image, byte[] bytes) => new(image, $"quarantine/{id}/{image}", "image/jpeg", bytes.Length, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
    private static byte[] Image(int width = 64, int height = 96)
    {
        using var bitmap = new SKBitmap(width, height); using var canvas = new SKCanvas(bitmap); canvas.Clear(SKColors.White);
        using var image = SKImage.FromBitmap(bitmap); using var data = image.Encode(SKEncodedImageFormat.Jpeg, 85); return data.ToArray();
    }
}
