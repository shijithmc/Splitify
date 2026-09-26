using System.Text.Json;
namespace Hisaab.Api.Receipts;
public sealed record ReceiptExtraction(string Classification, JsonElement? Document, string Model, string PromptVersion, string SchemaVersion, IReadOnlyList<string> Warnings, ReceiptProviderUsage? Usage = null);
