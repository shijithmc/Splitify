using System.Text.Json;
using System.Text.Json.Serialization;

namespace Hisaab.Application.Storage;

public sealed record StoreRow(string Pk, string Sk, long Version, JsonElement Data, long? ExpiresAtUnixSeconds = null)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter() }
    };

    public T Deserialize<T>() => Data.Deserialize<T>(JsonOptions)
        ?? throw new InvalidOperationException("Stored row cannot be deserialized to the requested type.");

    public static StoreRow Create<T>(string pk, string sk, long version, T value, long? expiresAtUnixSeconds = null)
        => new(pk, sk, version, JsonSerializer.SerializeToElement(value, JsonOptions), expiresAtUnixSeconds);
}
