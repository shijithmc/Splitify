using Hisaab.Domain;

namespace Hisaab.Api.Receipts.Infrastructure;

public static class ReceiptObjectKeys
{
    public static (string ReceiptId, string ImageId) ParseUpload(string key)
    {
        var parts = key.Split('/');
        if (parts.Length != 3 || parts[0] != "quarantine" || !Guid.TryParseExact(parts[1], "D", out _) || !Guid.TryParseExact(parts[2], "D", out _))
            throw new DomainException(422, "receipt_upload_invalid", "Invalid image upload identifier.");
        return (parts[1], parts[2]);
    }
    public static string Validate(string key)
    {
        var parts = key.Split('/');
        if (parts.Length != 3 || parts[0] is not ("quarantine" or "images" or "thumbs") || !Guid.TryParseExact(parts[1], "D", out _) ||
            !Guid.TryParseExact(parts[2].EndsWith(".jpg", StringComparison.Ordinal) ? parts[2][..^4] : parts[2], "D", out _))
            throw new DomainException(404, "receipt_not_found", "Receipt not found.");
        return key;
    }
}
