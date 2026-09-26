using System.Text.Json;
namespace Hisaab.Api.Shared;

public sealed record CommandResult(string Digest, JsonElement Result);
