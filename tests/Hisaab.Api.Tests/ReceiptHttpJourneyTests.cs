using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hisaab.Api.Receipts;
using Hisaab.Domain.Receipts;
using Microsoft.Extensions.DependencyInjection;
using SkiaSharp;

namespace Hisaab.Api.Tests;

public sealed class ReceiptHttpJourneyTests
{
    [Fact]
    public async Task RealLocalUploadReviewExpenseAndSharedMediaUsePublishedWireContract()
    {
        await using var factory=new ApiFactory();var j=await GroupJourney.Create(factory);var id=Guid.NewGuid().ToString();var imageId=Guid.NewGuid().ToString();
        using var bitmap=new SKBitmap(60,100);using var canvas=new SKCanvas(bitmap);canvas.Clear(SKColors.White);using var raster=SKImage.FromBitmap(bitmap);using var encoded=raster.Encode(SKEncodedImageFormat.Jpeg,80);var bytes=encoded.ToArray();
        var create=await ApiSession.Json(j.Alice.Client,HttpMethod.Post,$"{j.GroupPath}/receipts",new{id,scanRequested=false,images=new[]{new{id=imageId,contentType="image/jpeg",sizeBytes=bytes.Length,sha256=Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()}}});
        var upload=create.GetProperty("uploads")[0];using var data=new ByteArrayContent(bytes);data.Headers.ContentType=new("image/jpeg");using var response=await j.Alice.Client.PutAsync(upload.GetProperty("url").GetString(),data);Assert.Equal(HttpStatusCode.NoContent,response.StatusCode);
        await ApiSession.Json(j.Alice.Client,HttpMethod.Post,$"/v1/receipts/{id}/complete",new{version=1});
        await factory.Services.GetRequiredService<ReceiptWorker>().ProcessAsync(id);
        JsonElement status=default;
        for(var i=0;i<20;i++){status=await ApiSession.Json(j.Alice.Client,HttpMethod.Get,$"/v1/receipts/{id}");if(status.GetProperty("state").GetString()=="manual_ready")break;await Task.Delay(100);}
        Assert.Equal("manual_ready",status.GetProperty("state").GetString());
        var review=new ReceiptReview("Cafe",new(2026,9,26),"INR",10000,[new("dinner","Dinner","1",10000,10000,[j.AliceId,j.BobId])],[],true);
        var preview=await ApiSession.Json(j.Alice.Client,HttpMethod.Post,$"/v1/receipts/{id}/preview",review);Assert.Equal(5000,preview.GetProperty("shares").GetProperty(j.BobId).GetInt64());
        var body=JsonSerializer.SerializeToNode(j.Expense())!.AsObject();body["receipt"]=JsonSerializer.SerializeToNode(new{receiptId=id,version=status.GetProperty("version").GetInt64(),payerConfirmed=true,review});
        var saved=await ApiSession.Json(j.Alice.Client,HttpMethod.Post,$"{j.GroupPath}/expenses",body);Assert.Equal(id,saved.GetProperty("receiptId").GetString());
        var shared=await ApiSession.Json(j.Bob.Client,HttpMethod.Get,$"/v1/receipts/{id}");Assert.Equal("Cafe",shared.GetProperty("review").GetProperty("review").GetProperty("merchant").GetString());
        var ticket=(await ApiSession.Json(j.Bob.Client,HttpMethod.Post,$"/v1/receipts/{id}/media-ticket")).GetProperty("ticket").GetString();
        using var media=await j.Bob.Client.GetAsync($"/v1/receipts/{id}/media/{imageId}?ticket={ticket}&thumbnail=true&offset=0&length=1048576");Assert.Equal(HttpStatusCode.OK,media.StatusCode);Assert.Equal("image/jpeg",media.Content.Headers.ContentType!.MediaType);Assert.NotEmpty(await media.Content.ReadAsByteArrayAsync());
        await ApiSession.Error(j.Alice.Client,HttpMethod.Get,$"/v1/receipts/{id}/media/{imageId}?ticket={ticket}&thumbnail=true",HttpStatusCode.NotFound);
        var row=(await factory.Store.GetAsync($"RECEIPT#{id}","META"))!;await factory.Services.GetRequiredService<IReceiptBlobStore>().DeleteAsync(id);_ = row;
    }
}
