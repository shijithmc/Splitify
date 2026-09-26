using Amazon.CDK;
using Hisaab.Cdk;

var app = new App();
var environment = app.Node.TryGetContext("environment")?.ToString() ?? "dev";
if (environment is not ("dev" or "staging" or "prod"))
    throw new ArgumentException("environment must be dev, staging or prod.");
var apiAsset = app.Node.TryGetContext("apiAsset")?.ToString() ?? Path.GetFullPath("artifacts/api");
var workerAsset = app.Node.TryGetContext("workerAsset")?.ToString() ?? Path.GetFullPath("artifacts/workers");
RequirePublishedAssembly(apiAsset, "Hisaab.Api");
RequirePublishedAssembly(workerAsset, "Hisaab.Workers");
_ = new HisaabStack(app, $"Hisaab-{environment}", apiAsset, workerAsset);
app.Synth();

static void RequirePublishedAssembly(string directory, string assembly)
{
    foreach (var suffix in new[] { ".dll", ".deps.json", ".runtimeconfig.json" })
    {
        var file = Path.Combine(directory, assembly + suffix);
        if (!File.Exists(file)) throw new FileNotFoundException("Publish the real Lambda project, including runtime configuration, before synthesis.", file);
    }
}
