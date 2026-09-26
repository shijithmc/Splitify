using System.Text.Json;
using System.Text.RegularExpressions;
using Google.Apis.Auth.OAuth2;

namespace Hisaab.Api.Receipts.Infrastructure;

public sealed partial class WorkloadIdentityToken(IConfiguration configuration) : IVertexAccessToken
{
    private readonly Lazy<GoogleCredential> _credential = new(() => Create(configuration));
    public Task<string> GetAsync(CancellationToken ct) => _credential.Value.UnderlyingCredential.GetAccessTokenForRequestAsync(cancellationToken: ct);

    public static GoogleCredential Create(IConfiguration configuration)
    {
        var audience = configuration["Hisaab:Receipts:WorkloadIdentityAudience"] ?? "";
        var serviceAccount = configuration["Hisaab:Receipts:ServiceAccountEmail"] ?? "";
        if (!AudiencePattern().IsMatch(audience) || !ServiceAccountPattern().IsMatch(serviceAccount))
            throw new ReceiptProviderException("receipt_provider_unconfigured", false);
        // Generate the trusted credential config ourselves. No operator-supplied token,
        // metadata, file, executable or impersonation URL can redirect AWS credentials.
        var json = JsonSerializer.Serialize(new
        {
            type = "external_account", audience,
            subject_token_type = "urn:ietf:params:aws:token-type:aws4_request",
            token_url = "https://sts.googleapis.com/v1/token",
            service_account_impersonation_url = $"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{serviceAccount}:generateAccessToken",
            credential_source = new
            {
                environment_id = "aws1",
                regional_cred_verification_url = "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
            }
        });
        // AWS_REGION and temporary role credentials come from the Lambda environment.
        // Leaving metadata URLs absent deliberately disables IMDS fallback.
        return CredentialFactory.FromJson<AwsExternalAccountCredential>(json).ToGoogleCredential()
            .CreateScoped("https://www.googleapis.com/auth/cloud-platform");
    }
    [GeneratedRegex("^//iam\\.googleapis\\.com/projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+/providers/[a-z0-9-]+$", RegexOptions.CultureInvariant)]
    private static partial Regex AudiencePattern();
    [GeneratedRegex("^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", RegexOptions.CultureInvariant)]
    private static partial Regex ServiceAccountPattern();
}
