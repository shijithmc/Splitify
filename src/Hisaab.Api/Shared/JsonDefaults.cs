using System.Text.Json;
using System.Text.Json.Serialization;
namespace Hisaab.Api.Shared;

public static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = Create();
    private static JsonSerializerOptions Create() { var options = new JsonSerializerOptions(JsonSerializerDefaults.Web); options.Converters.Add(new JsonStringEnumConverter()); return options; }
}
