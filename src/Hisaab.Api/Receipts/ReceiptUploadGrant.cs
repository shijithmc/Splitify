namespace Hisaab.Api.Receipts;
public sealed record ReceiptUploadGrant(string Id, string Url, string Method, IReadOnlyDictionary<string,string> Headers, DateTimeOffset ExpiresAt);
