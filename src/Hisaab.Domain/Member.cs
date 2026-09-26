namespace Hisaab.Domain;

public sealed record Member(string Id, string? UserId, string DisplayName, bool IsPlaceholder = false,
    bool IsExternal = false, bool IsDeleted = false, bool HasLeft = false, DateTimeOffset? CreatedAt = null);
