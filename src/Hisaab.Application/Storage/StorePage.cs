namespace Hisaab.Application.Storage;

public sealed record StorePage(IReadOnlyList<StoreRow> Items, string? NextCursor);
