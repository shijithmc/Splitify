namespace Hisaab.Api.Identity;

public sealed record NotificationPreferences(bool Expenses = true, bool Payments = true, bool Invites = true, bool ReceiptDetails = false);
