namespace Hisaab.Application.Storage;

public sealed record StoreMutation(StoreMutationKind Kind, StoreKey Key, long? ExpectedVersion, StoreRow? Row = null)
{
    public static StoreMutation Put(StoreRow row, long? expectedVersion)
        => new(StoreMutationKind.Put, new(row.Pk, row.Sk), expectedVersion, row);

    public static StoreMutation Delete(string pk, string sk, long expectedVersion)
        => new(StoreMutationKind.Delete, new(pk, sk), expectedVersion);

    public static StoreMutation Condition(string pk, string sk, long? expectedVersion)
        => new(StoreMutationKind.Condition, new(pk, sk), expectedVersion);
}
