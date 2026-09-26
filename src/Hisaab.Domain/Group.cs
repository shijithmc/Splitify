namespace Hisaab.Domain;

public sealed record Group(string Id, string Name, GroupType Type, bool Archived, long Version,
    string CreatorId, IReadOnlyList<Member> Members, int ExpenseCount = 0, bool Deleted = false);
