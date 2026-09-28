using Hisaab.Api.Billing;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public sealed class ReceiptQuotaService(IAtomicStore store, IConfiguration config)
{
    public const string ConsentVersion = "2026-09-26-v1";
    public static string Month(DateTimeOffset now) => now.ToOffset(TimeSpan.FromMinutes(330)).ToString("yyyyMM", System.Globalization.CultureInfo.InvariantCulture);
    public static DateTimeOffset Reset(DateTimeOffset now)
    { var ist = now.ToOffset(TimeSpan.FromMinutes(330)); return new DateTimeOffset(ist.Year,ist.Month,1,0,0,0,ist.Offset).AddMonths(1); }
    public bool Enabled => config.GetValue<bool>("Hisaab:Receipts:Enabled") && config.GetValue<bool>("Hisaab:Receipts:ProviderValidated") && !config.GetValue<bool>("Hisaab:Receipts:EmergencyStop");
    public async Task<(int Cap, StoreRow? Row)> PlanAsync(string userId, CancellationToken ct)
    {
        var row = await store.GetAsync($"USER#{userId}","ENTITLEMENT#ad_free",ct);
        var entitlement = row?.Deserialize<Entitlement>().At(DateTimeOffset.UtcNow);
        var paid = entitlement is {AdFree:true,VerifiedAt:not null} && !entitlement.Status.StartsWith("sandbox_",StringComparison.Ordinal) && entitlement.Status is "active" or "grace" or "cancelled_but_active";
        return (paid?100:5,row);
    }
    public async Task<ReceiptAllowance> AllowanceAsync(string userId, CancellationToken ct)
    {
        var (cap,_) = await PlanAsync(userId,ct); var now = DateTimeOffset.UtcNow;
        var quota = (await store.GetAsync($"USER#{userId}",$"SCAN_QUOTA#{Month(now)}",ct))?.Deserialize<ReceiptQuota>() ?? new();
        var consent = (await store.GetAsync($"USER#{userId}","RECEIPT_CONSENT",ct))?.Deserialize<ReceiptConsent>();
        var controls=(await store.GetAsync("OPERATIONS","RECEIPTS",ct))?.Deserialize<ReceiptRuntimeControl>()??new();
        var budget=(await store.GetAsync("RECEIPT_BUDGET",now.ToString("yyyyMM",System.Globalization.CultureInfo.InvariantCulture),ct))?.Deserialize<ReceiptBudget>();
        var budgetUsd=config.GetValue<decimal>("Hisaab:Receipts:MonthlyBudgetUsd");var attemptUsd=config.GetValue<decimal>("Hisaab:Receipts:MaxAttemptCostUsd");
        var reason = !Enabled ? "scan_unavailable" : controls.EmergencyStop ? "scan_paused" : budgetUsd<=0||attemptUsd<=0||attemptUsd>budgetUsd ? "scan_budget_unconfigured" : budget?.CircuitUntil>now ? "scan_circuit_open" : cap==5 && (controls.PauseFree||config.GetValue<bool>("Hisaab:Receipts:PauseFree")) ? "scan_paused" : (budget?.ReservedMicrousd??0)+decimal.Ceiling(attemptUsd*1_000_000m)>decimal.Ceiling(budgetUsd*1_000_000m) ? "scan_paused" : quota.Used+quota.Reserved>=cap ? "scan_limit_reached" : null;
        return new(cap==100?"subscriber":"free",cap,quota.Used,quota.Reserved,Math.Max(0,cap-quota.Used-quota.Reserved),Reset(now),reason is null,reason,ConsentVersion,consent is { Accepted:true }&&consent.Version==ConsentVersion);
    }
    // Called only inside a conditional transaction builder; never invokes a provider.
    public async Task<(ReceiptRecord Receipt,IReadOnlyList<StoreMutation> Writes)> ReserveAsync(ReceiptRecord receipt, CancellationToken ct)
    {
        var uid = receipt.UploaderId ?? throw ReceiptAccess.Missing(); var now = DateTimeOffset.UtcNow;
        var allowance = await AllowanceAsync(uid,ct);
        if (!allowance.ConsentAccepted) throw new DomainException(422,"receipt_consent_required","Accept the Google processing notice before scanning.");
        if(!allowance.ScanAvailable && !(receipt.ReservationHeld && allowance.Reason=="scan_limit_reached")) throw new DomainException(allowance.Reason=="scan_limit_reached"?402:503,allowance.Reason!,"Scanning is unavailable. Enter manually with the photo attached.");
        var month = receipt.QuotaMonth ?? Month(now); var pk=$"USER#{uid}";
        var quotaRow=await store.GetAsync(pk,$"SCAN_QUOTA#{month}",ct); var quota=quotaRow?.Deserialize<ReceiptQuota>()??new();
        var (cap,entitlement)=await PlanAsync(uid,ct);
        if(!receipt.ReservationHeld && quota.Used+quota.Reserved>=cap) throw new DomainException(402,"scan_limit_reached","Your scan allowance is used. Enter manually or upgrade.");
        var admissionRow=await store.GetAsync(pk,"SCAN_ADMISSION",ct); var recent=(admissionRow?.Deserialize<ReceiptAdmission>().Attempts??[]).Where(t=>t>now.AddHours(-1)).ToList();
        if(recent.Count>=10) throw new DomainException(429,"scan_rate_limited","Ten scan attempts per hour. Enter manually or try later."); recent.Add(now);
        var consent=await store.GetAsync(pk,"RECEIPT_CONSENT",ct)??throw ReceiptAccess.Missing();
        var writes=new List<StoreMutation>{StoreMutation.Condition(pk,"ENTITLEMENT#ad_free",entitlement?.Version),StoreMutation.Condition(consent.Pk,consent.Sk,consent.Version),StoreMutation.Put(StoreRow.Create(pk,"SCAN_ADMISSION",(admissionRow?.Version??0)+1,new ReceiptAdmission(recent)),admissionRow?.Version)};
        if(!receipt.ReservationHeld) writes.Add(StoreMutation.Put(StoreRow.Create(pk,$"SCAN_QUOTA#{month}",(quotaRow?.Version??0)+1,quota with {Reserved=quota.Reserved+1}),quotaRow?.Version));
        return (receipt with{QuotaMonth=month,ReservationHeld=true},writes);
    }
    public async Task<IReadOnlyList<StoreMutation>> ReleaseAsync(ReceiptRecord receipt,bool success,CancellationToken ct)
    {
        if(!receipt.ReservationHeld||receipt.UploaderId is null||receipt.QuotaMonth is null) return [];
        var row=await store.GetAsync($"USER#{receipt.UploaderId}",$"SCAN_QUOTA#{receipt.QuotaMonth}",ct)??throw new InvalidOperationException("Missing scan reservation.");
        var quota=row.Deserialize<ReceiptQuota>(); if(quota.Reserved<=0)throw new InvalidOperationException("Invalid scan reservation.");
        return [StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,row.Version+1,quota with{Reserved=quota.Reserved-1,Used=quota.Used+(success&&!receipt.Counted?1:0)}),row.Version)];
    }
}
