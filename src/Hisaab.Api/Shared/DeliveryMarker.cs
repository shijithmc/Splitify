namespace Hisaab.Api.Shared;

internal sealed record DeliveryMarker(string Status, DateTimeOffset LeaseUntil, string AttemptId);
