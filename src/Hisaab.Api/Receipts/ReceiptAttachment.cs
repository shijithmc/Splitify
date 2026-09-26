using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed record ReceiptAttachment(Expense Draft, IReadOnlyList<StoreMutation> Writes);
