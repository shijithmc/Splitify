using Hisaab.Domain;
namespace Hisaab.Api.Contracts;

public sealed record SplitRequest(long AmountPaise, SplitMode Mode, IReadOnlyList<SplitParticipant> Participants);
