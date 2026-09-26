using System.Security.Cryptography;
using Hisaab.Domain;
using SkiaSharp;

namespace Hisaab.Api.Receipts.Infrastructure;

public static class ReceiptImageNormalizer
{
    public const int MaxBytes = 10 * 1024 * 1024;
    public static NormalizedReceiptImage Normalize(byte[] bytes, ReceiptUploadSlot slot)
    {
        if (bytes.Length is 0 or > MaxBytes || bytes.LongLength != slot.SizeBytes ||
            !Convert.ToHexString(SHA256.HashData(bytes)).Equals(slot.Sha256, StringComparison.OrdinalIgnoreCase))
            throw Invalid("Image size or checksum does not match the upload.");
        using var data = SKData.CreateCopy(bytes);
        using var codec = SKCodec.Create(data);
        if (codec is null || codec.Info.Width is < 1 or > 2048 || codec.Info.Height is < 1 or > 2048 ||
            codec.FrameCount > 1 || codec.EncodedOrigin != SKEncodedOrigin.TopLeft)
            throw Invalid("Use a still image, correctly oriented and resized to at most 2048 pixels.");
        var expected = codec.EncodedFormat switch { SKEncodedImageFormat.Jpeg => "image/jpeg", SKEncodedImageFormat.Png => "image/png", _ => "" };
        if (expected.Length == 0 || expected != slot.ContentType) throw Invalid("Upload a normalized JPEG or PNG image.");
        using var decoded = SKBitmap.Decode(codec);
        if (decoded is null) throw Invalid("This image could not be decoded. Choose another photo.");
        // A new raster and fresh encoder deliberately discard all source metadata.
        using var raster = new SKBitmap(new SKImageInfo(decoded.Width, decoded.Height, SKColorType.Bgra8888, SKAlphaType.Opaque));
        using var decodedImage = SKImage.FromBitmap(decoded);
        using (var canvas = new SKCanvas(raster)) { canvas.Clear(SKColors.White); canvas.DrawImage(decodedImage, 0, 0, new SKSamplingOptions(SKFilterMode.Linear)); }
        using var image = SKImage.FromBitmap(raster);
        using var encoded = image.Encode(SKEncodedImageFormat.Jpeg, 92);
        var scale = Math.Min(1d, 320d / Math.Max(raster.Width, raster.Height));
        using var small = raster.Resize(new SKImageInfo(Math.Max(1, (int)(raster.Width * scale)), Math.Max(1, (int)(raster.Height * scale))), new SKSamplingOptions(SKFilterMode.Linear));
        if (small is null || encoded is null) throw Invalid("This image could not be processed.");
        using var thumbnail = SKImage.FromBitmap(small);
        using var thumbBytes = thumbnail.Encode(SKEncodedImageFormat.Jpeg, 80);
        var result = encoded.ToArray();
        if (result.Length > MaxBytes || thumbBytes is null) throw Invalid("The processed image is too large.");
        return new(result, thumbBytes.ToArray(), raster.Width, raster.Height);
    }
    private static DomainException Invalid(string message) => new(422, "receipt_image_invalid", message);
}
