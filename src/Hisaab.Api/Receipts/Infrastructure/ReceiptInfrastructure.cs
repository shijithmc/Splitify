using Amazon.S3;
using Hisaab.Api.Identity;
using Hisaab.Domain;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace Hisaab.Api.Receipts.Infrastructure;

public static class ReceiptInfrastructure
{
    public static IServiceCollection AddReceiptInfrastructure(this IServiceCollection services, IConfiguration configuration, IHostEnvironment environment)
    {
        if (environment.IsDevelopment()) services.AddHostedService<LocalReceiptWorker>();
        services.TryAddSingleton<IReceiptBlobStore>(provider =>
        {
            if (!string.IsNullOrWhiteSpace(configuration["Hisaab:Receipts:BucketName"]))
                return new S3ReceiptBlobStore(new AmazonS3Client(), configuration);
            if (environment.IsDevelopment() || environment.IsEnvironment("Testing")) return new LocalReceiptBlobStore(configuration);
            return new UnavailableReceiptBlobStore();
        });
        return services;
    }
    public static WebApplication MapReceiptInfrastructure(this WebApplication app)
    {
        if (!app.Environment.IsDevelopment() && !app.Environment.IsEnvironment("Testing")) return app;
        app.MapPut("/v1/receipts/uploads/{receiptId}/{imageId}", async (HttpContext ctx, string receiptId, string imageId, ReceiptService receipts, IReceiptBlobStore store, CancellationToken ct) =>
        {
            if (store is not LocalReceiptBlobStore local) throw new DomainException(404, "receipt_not_found", "Receipt not found.");
            var actor = (Actor)ctx.Items["actor"]!;
            var slot = await receipts.AuthorizeUploadAsync(actor, receiptId, imageId, ct);
            if (ctx.Request.ContentLength != slot.SizeBytes || ctx.Request.ContentType != slot.ContentType)
                throw new DomainException(422, "receipt_upload_invalid", "Upload size and type must match the manifest.");
            var limit = ctx.Features.Get<IHttpMaxRequestBodySizeFeature>();
            if (limit is { IsReadOnly: false }) limit.MaxRequestBodySize = ReceiptImageNormalizer.MaxBytes;
            await local.AcceptUploadAsync(slot, ctx.Request.Body, ct);
            return Results.NoContent();
        });
        return app;
    }
}
