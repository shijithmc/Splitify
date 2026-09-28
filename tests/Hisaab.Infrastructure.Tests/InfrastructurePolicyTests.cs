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
            template.ResourceCountIs("AWS::Lambda::Function", 3);
            template.ResourceCountIs("AWS::DynamoDB::Table", 1);
            template.ResourceCountIs("AWS::SQS::Queue", 7);
            template.ResourceCountIs("AWS::Events::Rule", 5);
            template.ResourceCountIs("AWS::Lambda::EventSourceMapping", 5);
            template.ResourceCountIs("AWS::S3::Bucket", 1);
            template.HasResourceProperties("AWS::S3::Bucket", new Dictionary<string, object>
            {
                ["PublicAccessBlockConfiguration"] = new Dictionary<string, object>
                { ["BlockPublicAcls"] = true, ["BlockPublicPolicy"] = true, ["IgnorePublicAcls"] = true, ["RestrictPublicBuckets"] = true },
                ["BucketEncryption"] = new Dictionary<string, object>
                { ["ServerSideEncryptionConfiguration"] = new object[] { new Dictionary<string, object> { ["ServerSideEncryptionByDefault"] = new Dictionary<string, object> { ["SSEAlgorithm"] = "AES256" } } } }
            });
            template.HasResourceProperties("AWS::Lambda::Function", new Dictionary<string, object>
            {
                ["Handler"] = "Hisaab.Workers::Hisaab.Workers.ReceiptFunction::HandleAsync", ["ReservedConcurrentExecutions"] = 4
            });
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
            var routes = resources.EnumerateObject()
                .Where(resource => resource.Value.GetProperty("Type").GetString() == "AWS::ApiGatewayV2::Route")
                .ToDictionary(resource => resource.Value.GetProperty("Properties").GetProperty("RouteKey").GetString()!);
            Assert.Equal(3, routes.Count);
            template.ResourceCountIs("AWS::ApiGatewayV2::Integration", 1);
            var defaultRoute = routes["$default"].Value.GetProperty("Properties");
            var apiStage = resources.EnumerateObject()
                .Single(resource => resource.Value.GetProperty("Type").GetString() == "AWS::ApiGatewayV2::Stage");
            var stageProperties = apiStage.Value.GetProperty("Properties");
            Assert.Equal("$default", stageProperties.GetProperty("StageName").GetString());
            var defaults = stageProperties.GetProperty("DefaultRouteSettings");
            Assert.Equal(100, defaults.GetProperty("ThrottlingBurstLimit").GetInt32());
            Assert.Equal(50, defaults.GetProperty("ThrottlingRateLimit").GetInt32());
            var routeSettings = stageProperties.GetProperty("RouteSettings");
            Assert.Equal(2, routeSettings.EnumerateObject().Count());
            foreach (var routeKey in new[]
            {
                "POST /v1/groups/{groupId}/receipts",
                "POST /v1/receipts/{id}/complete"
            })
            {
                var route = routes[routeKey];
                var properties = route.Value.GetProperty("Properties");
                Assert.Equal(defaultRoute.GetProperty("ApiId").GetRawText(), properties.GetProperty("ApiId").GetRawText());
                Assert.Equal(defaultRoute.GetProperty("Target").GetRawText(), properties.GetProperty("Target").GetRawText());
                Assert.Equal(10, routeSettings.GetProperty(routeKey).GetProperty("ThrottlingBurstLimit").GetInt32());
                Assert.Equal(5, routeSettings.GetProperty(routeKey).GetProperty("ThrottlingRateLimit").GetInt32());
                Assert.Contains(apiStage.Value.GetProperty("DependsOn").EnumerateArray(), dependency => dependency.GetString() == route.Name);
            }
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
            Assert.DoesNotContain("ReceiptBudget80", json, StringComparison.Ordinal);
            Assert.DoesNotContain("ReceiptCircuitOpen", json, StringComparison.Ordinal);
            Assert.DoesNotContain("dynamodb:Scan", json, StringComparison.Ordinal);
            Assert.Contains("secretsmanager:GetSecretValue", json, StringComparison.Ordinal);
            Assert.Contains("HasConfigurationSecret", json, StringComparison.Ordinal);
            app.Synth();
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); }
    }
}
