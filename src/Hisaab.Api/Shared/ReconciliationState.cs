using Hisaab.Domain;
namespace Hisaab.Api.Shared;

internal sealed record ReconciliationState(string GroupId, long GroupVersion, string Stage, string? Cursor, IReadOnlyList<Balance> Balances);
