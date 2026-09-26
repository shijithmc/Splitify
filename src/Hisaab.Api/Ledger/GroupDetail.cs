using Hisaab.Domain;
namespace Hisaab.Api.Ledger;

public sealed record GroupDetail(string Id, string Name, GroupType Type, bool Archived, long Version, string CreatorId, IReadOnlyList<MemberDetail> Members, IReadOnlyList<Balance> Balances);
