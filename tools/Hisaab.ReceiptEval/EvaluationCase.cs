using Hisaab.Domain.Receipts;
namespace Hisaab.ReceiptEval;

public sealed record EvaluationCase(string Id, string Category, string Script, string[] Images, bool ContributorPermission, string Classification, ReceiptReview? Expected);
