using Hisaab.Application.Storage;
namespace Hisaab.Api.Shared;

public sealed record MutationResult(object Result, IReadOnlyList<StoreMutation> Writes);
