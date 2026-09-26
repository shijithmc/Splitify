using Hisaab.Domain;
namespace Hisaab.Api.Contracts;

public sealed record SettlementRequest(string Id, string FromId, string ToId, long AmountPaise, SettlementMethod Method);
