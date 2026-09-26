using Amazon.DynamoDBv2;
using Hisaab.Api.Billing;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Infrastructure.Storage;
using Hisaab.Support;
using System.Text.Json;

if (args.Length < 3 || args[0] is not ("lookup" or "lookup-transaction" or "lookup-scan" or "receipt-control" or "grant" or "revoke"))
{
    Console.Error.WriteLine("Usage: Hisaab.Support lookup-scan TABLE RECEIPT_UUID TICKET OPERATOR | receipt-control TABLE stop|pause-free|resume TICKET OPERATOR --confirm | lookup TABLE USER_UUID | lookup-transaction TABLE APP_STORE|PLAY_STORE TRANSACTION_ID | grant TABLE USER_UUID HOURS REASON OPERATOR --confirm | revoke TABLE USER_UUID REASON OPERATOR --confirm");
    return 2;
}
var command = args[0]; var table = args[1]; var userId = args[2];
if (command == "lookup-transaction" && args.Length != 4) { Console.Error.WriteLine("Usage: lookup-transaction TABLE APP_STORE|PLAY_STORE TRANSACTION_ID"); return 2; }
if (command is not ("lookup-transaction" or "lookup-scan" or "receipt-control") && !Guid.TryParse(userId, out _)) { Console.Error.WriteLine("USER_UUID must be a Hisaab account UUID."); return 2; }
using var client = new AmazonDynamoDBClient(); IAtomicStore store = new DynamoDbAtomicStore(client, table);
if (command is "lookup-scan" or "receipt-control")
{
    try
    {
        if(command=="lookup-scan")
        {
            if(args.Length!=5)throw new ArgumentException("Usage: lookup-scan TABLE RECEIPT_UUID TICKET OPERATOR");
            var result=await new ReceiptSupportService(store).LookupAsync(args[2],args[3],args[4]);
            if(result is null){Console.Error.WriteLine("Receipt not found; lookup was audited.");return 1;}
            Console.WriteLine(JsonSerializer.Serialize(result,new JsonSerializerOptions{WriteIndented=true}));return 0;
        }
        if(args.Length!=6||args[5]!="--confirm")throw new ArgumentException("Usage: receipt-control TABLE stop|pause-free|resume TICKET OPERATOR --confirm");
        var control=await new ReceiptSupportService(store).ControlAsync(args[2],args[3],args[4],true);
        Console.WriteLine(JsonSerializer.Serialize(control,new JsonSerializerOptions{WriteIndented=true}));return 0;
    }
    catch(ArgumentException ex){Console.Error.WriteLine(ex.Message);return 2;}
}
if (command == "lookup-transaction")
{
    TransactionLookupResult? attribution;
    try { attribution = await new SupportTransactionLookup(store).FindAsync(args[2], args[3]); }
    catch (ArgumentException ex) { Console.Error.WriteLine(ex.Message); return 2; }
    catch (InvalidDataException ex) { Console.Error.WriteLine(ex.Message); return 1; }
    if (attribution is null) { Console.Error.WriteLine("No received webhook has indexed that transaction for this store. Check store, environment and webhook processing; this does not prove no purchase exists."); return 1; }
    userId = attribution.RecordedOwnerUserId;
    Console.WriteLine(JsonSerializer.Serialize(new { transactionAttribution = attribution, note = "Recorded webhook attribution; verify current RevenueCat ownership and entitlement before any support action." }, new JsonSerializerOptions { WriteIndented = true }));
}
var pk = $"USER#{userId}"; var profile = await store.GetAsync(pk, "PROFILE");
if (profile is null) { Console.Error.WriteLine("Account not found."); return 1; }
if (command is "lookup" or "lookup-transaction")
{
    var entitlement = await store.GetAsync(pk, "ENTITLEMENT#ad_free"); var grant = await store.GetAsync(pk, "SUPPORT_GRANT");
    Console.WriteLine(JsonSerializer.Serialize(new { userId, accountStatus = profile.Data.GetProperty("status").GetString(), entitlement = entitlement?.Data, supportGrant = grant?.Data }, new JsonSerializerOptions { WriteIndented = true }));
    var history = await store.QueryAsync(pk, "BILLING#", 100);
    Console.WriteLine(JsonSerializer.Serialize(new { billingHistory = history.Items.Select(row => row.Data), history.NextCursor, order = "oldest_first" }, new JsonSerializerOptions { WriteIndented = true }));
    return 0;
}
if (!args.Contains("--confirm") || (command == "grant" ? args.Length < 7 : args.Length < 6)) { Console.Error.WriteLine("A reason, operator identity and --confirm are required."); return 2; }
if (profile.Data.GetProperty("status").GetString() != "active") { Console.Error.WriteLine("Support grants require an active account."); return 2; }
var reason = command == "grant" ? args[4] : args[3]; var operatorId = command == "grant" ? args[5] : args[4];
if (string.IsNullOrWhiteSpace(reason) || string.IsNullOrWhiteSpace(operatorId)) return 2;
var previous = await store.GetAsync(pk, "SUPPORT_GRANT"); var now = DateTimeOffset.UtcNow; var writes = new List<StoreMutation> { StoreMutation.Condition(pk, "PROFILE", profile.Version) };
if (command == "grant")
{
    if (!int.TryParse(args[3], out var hours) || hours is < 1 or > 168) { Console.Error.WriteLine("Grant must expire in 1–168 hours."); return 2; }
    var entitlement = new Entitlement(true, "support_grant", now.AddHours(hours), "support", now);
    writes.Add(StoreMutation.Put(StoreRow.Create(pk, "SUPPORT_GRANT", (previous?.Version ?? 0) + 1, entitlement, now.AddHours(hours).ToUnixTimeSeconds()), previous?.Version));
}
else if (previous is not null) writes.Add(StoreMutation.Delete(pk, "SUPPORT_GRANT", previous.Version));
writes.Add(StoreMutation.Put(StoreRow.Create(pk, $"BILLING#{now:O}#{Ids.New()}", 1, new { action = command, reason, operatorId, createdAt = now }), null));
await store.TransactAsync(writes); Console.WriteLine("Audited support action recorded."); return 0;
