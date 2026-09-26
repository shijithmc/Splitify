namespace Hisaab.Api.Receipts.Infrastructure;

public sealed class LocalReceiptWorker(ReceiptWorker worker, ILogger<LocalReceiptWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            try { await worker.RunAsync(ct: stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception ex) { logger.LogWarning("Receipt worker retry required: {ErrorType}", ex.GetType().Name); }
        }
    }
}
