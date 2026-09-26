using System.Text.Json;

namespace Hisaab.Api.Ledger;

public sealed record ActivityDetail(string Id, string GroupId, string Kind, string ActorId,
    string Description, DateTimeOffset CreatedAt, string EntityId, string ActorName, JsonElement? Changes);
