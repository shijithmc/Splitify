namespace Hisaab.Domain;

public sealed record Settlement(string Id, string GroupId, string FromId, string ToId,
    long AmountPaise, SettlementMethod Method, long Version, bool Disputed,
    string CreatedBy, DateTimeOffset CreatedAt);
