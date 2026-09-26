using Hisaab.Api.Identity;
using Hisaab.Domain.Receipts;
using Hisaab.Application.Storage;
using Hisaab.Domain;
namespace Hisaab.Api.Receipts;

public static class ReceiptEndpoints
{
    public static void MapReceipts(this WebApplication app)
    {
        static Actor Current(HttpContext ctx)=>(Actor)ctx.Items["actor"]!;
        static string Key(HttpContext ctx)=>ctx.Request.Headers["Idempotency-Key"].ToString();
        app.MapGet("/v1/receipts/allowance",(HttpContext ctx,ReceiptService receipts,CancellationToken ct)=>receipts.AllowanceAsync(Current(ctx),ct));
        app.MapPut("/v1/receipts/consent",(HttpContext ctx,ReceiptConsentRequest input,ReceiptService receipts,CancellationToken ct)=>receipts.ConsentAsync(Current(ctx),Key(ctx),input,ct));
        app.MapPost("/v1/groups/{groupId}/receipts",(HttpContext ctx,string groupId,ReceiptCreateRequest input,ReceiptService receipts,CancellationToken ct)=>receipts.CreateAsync(Current(ctx),Key(ctx),groupId,input,ct));
        app.MapGet("/v1/receipts/{id}",(HttpContext ctx,string id,ReceiptService receipts,CancellationToken ct)=>receipts.GetAsync(Current(ctx),id,ct));
        app.MapPost("/v1/receipts/{id}/complete",(HttpContext ctx,string id,ReceiptVersionRequest input,ReceiptService receipts,CancellationToken ct)=>receipts.CompleteAsync(Current(ctx),Key(ctx),id,input,ct));
        app.MapPost("/v1/receipts/{id}/retry",(HttpContext ctx,string id,ReceiptVersionRequest input,ReceiptService receipts,CancellationToken ct)=>receipts.RetryAsync(Current(ctx),Key(ctx),id,input,ct));
        app.MapPost("/v1/receipts/{id}/preview",async(HttpContext ctx,string id,ReceiptReview input,ReceiptAccess access,CancellationToken ct)=>
        {
            var receipt=(await access.ReceiptAsync(Current(ctx),id,false,ct)).Deserialize<ReceiptRecord>();var group=(await access.GroupAsync(receipt.GroupId,Current(ctx).User.Id,ct)).Deserialize<Group>();
            return ReceiptSplitEngine.Calculate(input,group.Members.Where(m=>!m.HasLeft&&!m.IsDeleted).Select(m=>m.Id).ToArray(),false);
        });
        app.MapPost("/v1/receipts/{id}/duplicate-check",(HttpContext ctx,string id,ReceiptReview input,ReceiptService receipts,CancellationToken ct)=>receipts.DuplicatesAsync(Current(ctx),id,input,ct));
        app.MapPost("/v1/receipts/{id}/media-ticket",(HttpContext ctx,string id,ReceiptService receipts,CancellationToken ct)=>receipts.TicketAsync(Current(ctx),id,ct));
        app.MapGet("/v1/receipts/{id}/media/{mediaId}",async(HttpContext ctx,string id,string mediaId,string ticket,bool? thumbnail,long? offset,int? length,ReceiptService receipts,CancellationToken ct)=>
        {
            var content=await receipts.MediaAsync(Current(ctx),id,mediaId,ticket,thumbnail??false,offset??0,length??1048576,ct);ctx.Response.Headers.CacheControl="private, no-store";ctx.Response.Headers["X-Content-Type-Options"]="nosniff";return Results.Bytes(content.Bytes,content.ContentType);
        });
        app.MapDelete("/v1/receipts/{id}/images",async(HttpContext ctx,string id,ReceiptService receipts,CancellationToken ct)=>
        {var input=await ctx.Request.ReadFromJsonAsync<ReceiptVersionRequest>(ct)??new(0);return await receipts.RemoveImagesAsync(Current(ctx),Key(ctx),id,input,ct);});
        app.MapPost("/v1/groups/{groupId}/expenses/{expenseId}/receipt-flags",(HttpContext ctx,string groupId,string expenseId,ReceiptFlagRequest input,ReceiptService receipts,CancellationToken ct)=>receipts.FlagAsync(Current(ctx),Key(ctx),groupId,expenseId,input,ct));
    }
}
