using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptBudgetService(IAtomicStore store,IConfiguration config)
{
    public async Task<IReadOnlyList<StoreMutation>> AdmitAsync(bool paid,CancellationToken ct)
    {
        var control=await store.GetAsync("OPERATIONS","RECEIPTS",ct);var value=control?.Deserialize<ReceiptRuntimeControl>()??new();
        if(value.EmergencyStop||value.PauseFree&&!paid)throw new DomainException(503,"scan_paused","Scanning is paused. Enter manually.");
        var configured=config.GetValue<decimal>("Hisaab:Receipts:MonthlyBudgetUsd");var perAttempt=config.GetValue<decimal>("Hisaab:Receipts:MaxAttemptCostUsd");
        if(configured<=0||perAttempt<=0||perAttempt>configured)throw new DomainException(503,"scan_budget_unconfigured","Scanning is not configured. Enter manually.");
        var ceiling=checked((long)decimal.Ceiling(configured*1_000_000m));var charge=checked((long)decimal.Ceiling(perAttempt*1_000_000m));
        var month=DateTimeOffset.UtcNow.ToString("yyyyMM",System.Globalization.CultureInfo.InvariantCulture);var row=await store.GetAsync("RECEIPT_BUDGET",month,ct);var budget=row?.Deserialize<ReceiptBudget>()??new(0,0);
        if(budget.CircuitUntil>DateTimeOffset.UtcNow)throw new DomainException(503,"scan_circuit_open","Reading bills is temporarily unavailable. Enter manually.");
        if(checked(budget.ReservedMicrousd+charge)>ceiling)throw new DomainException(503,"scan_paused","Scanning is paused. Enter manually.");
        var updated=budget with{ReservedMicrousd=checked(budget.ReservedMicrousd+charge),Attempts=checked(budget.Attempts+1),Alarm80=budget.Alarm80||budget.ReservedMicrousd+charge>=ceiling*0.8m};
        // Conservative per-attempt liability remains charged even after timeout/failure; actual
        // provider billing can lag. Every plan shares this hard admission ceiling.
        return [StoreMutation.Condition("OPERATIONS","RECEIPTS",control?.Version),StoreMutation.Put(StoreRow.Create("RECEIPT_BUDGET",month,(row?.Version??0)+1,updated),row?.Version)];
    }
    public async Task<IReadOnlyList<StoreMutation>> OutcomeAsync(bool providerFailure,CancellationToken ct)
    {
        var month=DateTimeOffset.UtcNow.ToString("yyyyMM",System.Globalization.CultureInfo.InvariantCulture);var row=await store.GetAsync("RECEIPT_BUDGET",month,ct);if(row is null)return [];
        var current=row.Deserialize<ReceiptBudget>();var count=providerFailure?current.ConsecutiveFailures+1:0;
        return [StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,row.Version+1,current with{ConsecutiveFailures=count,CircuitUntil=count>=5?DateTimeOffset.UtcNow.AddMinutes(5):null}),row.Version)];
    }
}
