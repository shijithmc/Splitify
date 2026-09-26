using System.Text.Json;
using Hisaab.Api.Receipts;
using Hisaab.Domain.Receipts;
namespace Hisaab.Api.Tests;
internal sealed class ReceiptTestExtractor : IReceiptExtractor
{
    public int Calls;
    public Func<Task<ReceiptExtraction>>? Handler {get;set;}
    public Task<ReceiptExtraction> ExtractAsync(IReadOnlyList<ReceiptMedia> media,CancellationToken ct=default)
    {Interlocked.Increment(ref Calls);return Handler?.Invoke()??Task.FromResult(new ReceiptExtraction("bill",JsonSerializer.SerializeToElement(new ReceiptReview("Cafe",DateOnly.FromDateTime(DateTime.UtcNow),"INR",100,[],[])),"test-only","1","1",[]));}
}
