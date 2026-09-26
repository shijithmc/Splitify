namespace Hisaab.Domain;

public sealed record Activity(string Id, string GroupId, string Kind, string ActorId,
    string Description, DateTimeOffset CreatedAt, string EntityId);
