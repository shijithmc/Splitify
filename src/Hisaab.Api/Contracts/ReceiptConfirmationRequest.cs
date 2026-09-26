using Hisaab.Domain.Receipts;
namespace Hisaab.Api.Contracts;

public sealed record ReceiptConfirmationRequest(string ReceiptId, long Version,
    ReceiptReview Review, bool PayerConfirmed);
