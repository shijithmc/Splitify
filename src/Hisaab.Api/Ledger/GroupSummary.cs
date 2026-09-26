using Hisaab.Domain;
namespace Hisaab.Api.Ledger;

public sealed record GroupSummary(string Id, string Name, GroupType Type, bool Archived, long Version, int MemberCount, long NetPaise);
