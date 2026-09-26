namespace Hisaab.Support;

public sealed record TransactionLookupResult(string RecordedOwnerUserId, string Store, string? EventId);
