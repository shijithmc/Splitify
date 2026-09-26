using Hisaab.Domain;
namespace Hisaab.Api.Contracts;

public sealed record ExpenseRequest(string Id, string Description, long AmountPaise, DateOnly Date, string PayerId, SplitMode Mode, IReadOnlyList<SplitParticipant> Participants, long Version = 0);
