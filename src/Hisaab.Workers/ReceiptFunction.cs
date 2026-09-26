using System.Text.Json;
using Amazon.Lambda.Core;
using Amazon.SQS;
using Amazon.SQS.Model;
using Hisaab.Api.Receipts;
using Hisaab.Application.Storage;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Hisaab.Workers;

public sealed class ReceiptFunction
{
    public async Task HandleAsync(JsonElement input, ILambdaContext context)
    {
        var host = await Function.GetHostAsync();
        var remaining = context.RemainingTime - TimeSpan.FromSeconds(5);
        if (remaining <= TimeSpan.Zero) throw new TimeoutException("Insufficient time to safely process receipt work.");
        using var budget = new CancellationTokenSource(remaining > TimeSpan.FromSeconds(50) ? TimeSpan.FromSeconds(50) : remaining);
        var worker = host.Services.GetRequiredService<ReceiptWorker>();
        if (input.TryGetProperty("Records", out var records))
        {
            foreach (var record in records.EnumerateArray())
            {
                if (!record.TryGetProperty("eventSource", out var source)) throw new InvalidDataException("Missing receipt event source.");
                if (source.GetString() == "aws:dynamodb")
                {
                    // Streams dispatch identifiers only. The SQS invocation performs inference.
                    var keys = record.GetProperty("dynamodb").GetProperty("Keys");
                    if (keys.GetProperty("PK").GetProperty("S").GetString() != "WORK#receipt-scan") continue;
                    var id = keys.GetProperty("SK").GetProperty("S").GetString();
                    if (!Guid.TryParse(id, out _)) throw new InvalidDataException("Invalid receipt work identifier.");
                    var work = await host.Services.GetRequiredService<IAtomicStore>().GetAsync("WORK#receipt-scan", id!, budget.Token);
                    if (work is null) continue;
                    var delay = ReceiptDispatch.DelaySeconds(work.Deserialize<ReceiptWork>().DueAt, DateTimeOffset.UtcNow);
                    var queue = host.Services.GetRequiredService<IConfiguration>()["Hisaab:Receipts:QueueUrl"] ?? throw new InvalidOperationException("Receipt queue is required.");
                    using var sqs = new AmazonSQSClient();
                    await sqs.SendMessageAsync(new SendMessageRequest { QueueUrl = queue, MessageBody = JsonSerializer.Serialize(new { receiptId = id }), DelaySeconds = delay }, budget.Token);
                }
                else if (source.GetString() == "aws:sqs")
                {
                    using var body = JsonDocument.Parse(record.GetProperty("body").GetString()!);
                    var id = body.RootElement.GetProperty("receiptId").GetString();
                    if (!Guid.TryParse(id, out _)) throw new InvalidDataException("Invalid receipt work identifier.");
                    await worker.ProcessAsync(id!, budget.Token);
                }
                else throw new InvalidDataException("Unsupported receipt event source.");
            }
        }
        else
        {
            // Repair lost stream notifications and expired leases using the durable, paged cursor.
            await worker.RunAsync(ct: budget.Token);
        }
        await EmitHealthAsync(host.Services.GetRequiredService<IAtomicStore>(), context, budget.Token);
    }
    private static async Task EmitHealthAsync(IAtomicStore store, ILambdaContext context, CancellationToken ct)
    {
        var row = await store.GetAsync("RECEIPT_BUDGET", DateTimeOffset.UtcNow.ToString("yyyyMM", System.Globalization.CultureInfo.InvariantCulture), ct);
        var budget = row?.Deserialize<ReceiptBudget>();
        // EMF contains only aggregate operational values, never receipt/account identifiers or content.
        context.Logger.LogLine(JsonSerializer.Serialize(new
        {
            _aws = new { Timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), CloudWatchMetrics = new[] { new
            {
                Namespace = "Hisaab/Receipts", Dimensions = new[] { Array.Empty<string>() },
                Metrics = new[] { new { Name = "Budget80", Unit = "Count" }, new { Name = "CircuitOpen", Unit = "Count" } }
            } } },
            Budget80 = budget?.Alarm80 == true ? 1 : 0,
            CircuitOpen = budget?.CircuitUntil > DateTimeOffset.UtcNow ? 1 : 0
        }));
    }
}
