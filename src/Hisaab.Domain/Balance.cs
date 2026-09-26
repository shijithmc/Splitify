namespace Hisaab.Domain;

// Positive entries mean this participant is owed by the counterparty.
public sealed record Balance(string ParticipantId, long NetPaise,
    IReadOnlyDictionary<string, long> Counterparties);
