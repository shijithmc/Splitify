using Hisaab.Api.Identity;
using Hisaab.Api.Receipts;
using Hisaab.Api.Shared;
using Hisaab.Application.Storage;
using Hisaab.Domain;
using Hisaab.Infrastructure.Storage;
using Microsoft.Extensions.Configuration;
namespace Hisaab.Api.Tests;
internal sealed class ReceiptTestContext
{
    public LocalAtomicStore Store {get;}=new(null);
    public ReceiptTestBlobs Blobs {get;}=new();
    public ReceiptTestExtractor Extractor {get;}=new();
    public IConfiguration Config {get;}=new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?>{
        ["Hisaab:Receipts:Enabled"]="true",["Hisaab:Receipts:ProviderValidated"]="true",["Hisaab:Receipts:MonthlyBudgetUsd"]="10",["Hisaab:Receipts:MaxAttemptCostUsd"]="0.01"}).Build();
    public ReceiptQuotaService Quotas=>new(Store,Config);
    public ReceiptBudgetService Budget=>new(Store,Config);
    public ReceiptLifecycle Lifecycle=>new(Store,Quotas,Blobs,Config);
    public ReceiptService Service=>new(Store,new CommandExecutor(Store),new ReceiptAccess(Store),Quotas,new ReceiptDocuments(Store),Blobs,new ReceiptAttachmentService(Store,Quotas,Config),Config);
    public ReceiptWorker Worker=>new(Store,Blobs,Extractor,Quotas,Lifecycle,Budget,Config);
    public Actor Actor {get;private set;}=null!;
    public Actor Other {get;private set;}=null!;
    public string GroupId {get;}=Guid.NewGuid().ToString();
    public static async Task<ReceiptTestContext> Create()
    {
        var c=new ReceiptTestContext();c.Actor=await c.User("Alice");c.Other=await c.User("Bob");
        var group=new Group(c.GroupId,"Trip",GroupType.Trip,false,1,c.Actor.User.Id,[new("alice",c.Actor.User.Id,"Alice"),new("bob",c.Other.User.Id,"Bob")]);
        await c.Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"GROUP#{c.GroupId}","META",1,group),null)]);
        await c.Service.ConsentAsync(c.Actor,Guid.NewGuid().ToString(),new(ReceiptQuotaService.ConsentVersion,true),default);return c;
    }
    private async Task<Actor> User(string name)
    {
        var user=new UserAccount(Guid.NewGuid().ToString(),name,null,"active",DateTimeOffset.UtcNow);var hash=Guid.NewGuid().ToString();
        await Store.TransactAsync([StoreMutation.Put(StoreRow.Create($"USER#{user.Id}","PROFILE",1,user),null),StoreMutation.Put(StoreRow.Create($"SESSION#{hash}","META",1,new SessionRecord(user.Id,"refresh",DateTimeOffset.UtcNow.AddMinutes(30),DateTimeOffset.UtcNow.AddDays(30),DateTimeOffset.UtcNow)),null)]);
        return new(user,1,hash,1,DateTimeOffset.UtcNow);
    }
    public async Task<string> CreateReceipt(bool scan=true)
    {
        var id=Guid.NewGuid().ToString();await Service.CreateAsync(Actor,Guid.NewGuid().ToString(),GroupId,new(id,scan,[new(Guid.NewGuid().ToString(),"image/jpeg",10,new string('a',64))]),default);
        await Service.CompleteAsync(Actor,Guid.NewGuid().ToString(),id,new(1),default);await Worker.ProcessAsync(id);return id;
    }
    public async Task<ReceiptRecord> Receipt(string id)=>(await Store.GetAsync($"RECEIPT#{id}","META"))!.Deserialize<ReceiptRecord>();
    public async Task PutReceipt(ReceiptRecord value)
    {var row=(await Store.GetAsync($"RECEIPT#{value.Id}","META"))!;await Store.TransactAsync([StoreMutation.Put(StoreRow.Create(row.Pk,row.Sk,row.Version+1,value with{Version=row.Version+1}),row.Version)]);}
}
