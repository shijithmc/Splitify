namespace Hisaab.Api.Shared;

internal sealed record ScanCheckpoint(bool Running, string? Cursor);
