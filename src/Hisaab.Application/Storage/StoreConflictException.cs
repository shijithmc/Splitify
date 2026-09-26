namespace Hisaab.Application.Storage;

public sealed class StoreConflictException(string message = "Data changed. Refresh and try again.", Exception? inner = null)
    : Exception(message, inner);
