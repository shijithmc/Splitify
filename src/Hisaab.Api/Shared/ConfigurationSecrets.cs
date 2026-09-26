using System.Text.Json;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
namespace Hisaab.Api.Shared;

public static class ConfigurationSecrets
{
    public static async Task LoadAsync(ConfigurationManager configuration)
    {
        var arn = configuration["Hisaab:SecretsArn"]; if (string.IsNullOrWhiteSpace(arn)) return;
        using var client = new AmazonSecretsManagerClient();
        var response = await client.GetSecretValueAsync(new GetSecretValueRequest { SecretId = arn });
        using var data = JsonDocument.Parse(response.SecretString);
        var values = new Dictionary<string, string?>();
        foreach (var field in data.RootElement.EnumerateObject()) { if (!field.Name.StartsWith("Hisaab:", StringComparison.Ordinal) || field.Value.ValueKind != JsonValueKind.String) throw new InvalidOperationException("Configuration secret must contain flat Hisaab: configuration keys with string values."); values[field.Name] = field.Value.GetString(); }
        configuration.AddInMemoryCollection(values);
    }
}
