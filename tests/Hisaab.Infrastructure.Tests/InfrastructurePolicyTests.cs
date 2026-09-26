using System.Text.Json;
using Amazon.CDK;
using Amazon.CDK.Assertions;
using Hisaab.Cdk;

namespace Hisaab.Infrastructure.Tests;

public sealed class InfrastructurePolicyTests
{
    [Fact]
    public void SynthesizedStackHasProtectedTableSupportedLambdasAndNoProhibitedResources()
    {
        var root = Path.Combine(Path.GetTempPath(), "hisaab-cdk-" + Guid.NewGuid().ToString("N"));
        var assets = Path.Combine(root, "test-assets");
        Directory.CreateDirectory(assets);
        File.WriteAllText(Path.Combine(assets, "asset.txt"), "Synthesis-only test asset; not a deployable Lambda.");
        try
        {
            var app = new App(new AppProps { Outdir = Path.Combine(root, "cdk.out") });
            var stack = new HisaabStack(app, "Hisaab-policy-test", assets, assets);
            var template = Template.FromStack(stack);
            template.ResourceCountIs("AWS::Lambda::Function", 2);
            template.ResourceCountIs("AWS::DynamoDB::Table", 1);
            template.ResourceCountIs("AWS::SQS::Queue", 5);
            template.ResourceCountIs("AWS::Events::Rule", 4);
            template.ResourceCountIs("AWS::Lambda::EventSourceMapping", 3);
            template.HasResourceProperties("AWS::DynamoDB::Table", new Dictionary<string, object>
            {
                ["BillingMode"] = "PAY_PER_REQUEST",
                ["DeletionProtectionEnabled"] = true,
                ["PointInTimeRecoverySpecification"] = new Dictionary<string, object> { ["PointInTimeRecoveryEnabled"] = true },
                ["TimeToLiveSpecification"] = new Dictionary<string, object> { ["AttributeName"] = "ExpiresAt", ["Enabled"] = true }
            });
            template.HasResourceProperties("AWS::CloudWatch::Alarm", new Dictionary<string, object>
            {
                ["ComparisonOperator"] = "GreaterThanOrEqualToThreshold",
                ["Threshold"] = 0.5,
                ["EvaluationPeriods"] = 1,
                ["DatapointsToAlarm"] = 1,
                ["Metrics"] = Match.ArrayWith(new object[]
                {
                    Match.ObjectLike(new Dictionary<string, object> { ["Expression"] = "IF(requests > 0, 100 * errors / requests, 0)", ["ReturnData"] = true }),
                    Match.ObjectLike(new Dictionary<string, object>
                    {
                        ["Id"] = "errors", ["MetricStat"] = Match.ObjectLike(new Dictionary<string, object>
                        {
                            ["Stat"] = "Sum", ["Period"] = 300,
                            ["Metric"] = Match.ObjectLike(new Dictionary<string, object>
                            {
                                ["Namespace"] = "AWS/ApiGateway", ["MetricName"] = "5xx",
                                ["Dimensions"] = Match.ArrayWith(new object[]
                                {
                                    Match.ObjectLike(new Dictionary<string, object> { ["Name"] = "ApiId" }),
                                    new Dictionary<string, object> { ["Name"] = "Stage", ["Value"] = "$default" }
                                })
                            })
                        })
                    }),
                    Match.ObjectLike(new Dictionary<string, object>
                    {
                        ["Id"] = "requests", ["MetricStat"] = Match.ObjectLike(new Dictionary<string, object>
                        {
                            ["Stat"] = "Sum", ["Period"] = 300,
                            ["Metric"] = Match.ObjectLike(new Dictionary<string, object> { ["Namespace"] = "AWS/ApiGateway", ["MetricName"] = "Count" })
                        })
                    })
                })
            });
            var json = JsonSerializer.Serialize(template.ToJSON());
            using var document = JsonDocument.Parse(json);
            var resources = document.RootElement.GetProperty("Resources");
            foreach (var resource in resources.EnumerateObject())
            {
                var type = resource.Value.GetProperty("Type").GetString()!;
                Assert.DoesNotContain("OpenSearch", type, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain("Elasticsearch", type, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain("WAF", type, StringComparison.OrdinalIgnoreCase);
                Assert.DoesNotContain("SearchCache", resource.Name, StringComparison.OrdinalIgnoreCase);
                if (type == "AWS::Lambda::Function")
                {
                    var properties = resource.Value.GetProperty("Properties");
                    Assert.Equal("dotnet10", properties.GetProperty("Runtime").GetString());
                    Assert.Equal("arm64", properties.GetProperty("Architectures")[0].GetString());
                    Assert.False(properties.TryGetProperty("SnapStart", out _));
                    Assert.Equal("Production", properties.GetProperty("Environment").GetProperty("Variables").GetProperty("ASPNETCORE_ENVIRONMENT").GetString());
                }
                if (type == "AWS::DynamoDB::Table")
                    Assert.Equal("Retain", resource.Value.GetProperty("DeletionPolicy").GetString());
            }
            Assert.DoesNotContain("dynamodb:Scan", json, StringComparison.Ordinal);
            Assert.Contains("secretsmanager:GetSecretValue", json, StringComparison.Ordinal);
            Assert.Contains("HasConfigurationSecret", json, StringComparison.Ordinal);
            app.Synth();
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }
}
