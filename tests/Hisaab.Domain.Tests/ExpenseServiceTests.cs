using Hisaab.Domain;

namespace Hisaab.Domain.Tests;

public sealed class ExpenseServiceTests
{
    [Fact]
    public void CreateRecomputesSharesAndIgnoresDraftAuditFields()
    {
        var expense = ExpenseService.Create(Fixtures.Group(), Fixtures.Expense() with
        { Shares = new Dictionary<string, long>(), Version = 20, CreatedBy = "fake", DeletedAt = Fixtures.Now }, "ua", Fixtures.Now);
        Assert.Equal("Dinner", expense.Description);
        Assert.Equal(1, expense.Version);
        Assert.Null(expense.DeletedAt);
        Assert.Equal("ua", expense.CreatedBy);
        Assert.Equal(3334, expense.Shares["a"]);
    }

    [Fact]
    public void DescriptionCountsUnicodeScalarsAndTrims()
    {
        ExpenseService.Create(Fixtures.Group(), Fixtures.Expense() with { Description = string.Concat(Enumerable.Repeat("🧾", 100)) }, "ua", Fixtures.Now);
        Assert.Throws<DomainException>(() => ExpenseService.Create(Fixtures.Group(), Fixtures.Expense() with
        { Description = string.Concat(Enumerable.Repeat("🧾", 101)) }, "ua", Fixtures.Now));
        Assert.Throws<DomainException>(() => ExpenseService.Create(Fixtures.Group(), Fixtures.Expense() with { Description = "  " }, "ua", Fixtures.Now));
    }

    [Fact]
    public void OriginalParticipantAuthorizationCannotBeGainedThroughEditedDraft()
    {
        var original = Fixtures.Expense("a", 100, SplitMode.Equal, new("a"), new("b"));
        Assert.Equal("expense_participant_required", Assert.Throws<DomainException>(() => ExpenseService.Update(Fixtures.Group(), original,
            Fixtures.Expense(), "uc", 1, Fixtures.Now)).Code);
        var changed = ExpenseService.Update(Fixtures.Group(), original, Fixtures.Expense(), "ub", 1, Fixtures.Now);
        Assert.Equal(2, changed.Version);
        Assert.Equal(original.CreatedBy, changed.CreatedBy);
    }

    [Fact]
    public void FormerMembersCannotBeAssignedOrModifyExpenses()
    {
        var group = Fixtures.Group(new("a", "ua", "A"), new("b", "ub", "B", HasLeft: true), new("c", "uc", "C"));
        Assert.Equal("invalid_expense_member", Assert.Throws<DomainException>(() => ExpenseService.Create(group, Fixtures.Expense(), "ua", Fixtures.Now)).Code);
        Assert.Equal("group_not_found", Assert.Throws<DomainException>(() => ExpenseService.Delete(group, Fixtures.Expense(), "ub", 1, Fixtures.Now)).Code);
    }

    [Fact]
    public void StaleAndRepeatedMutationsAreConflicts()
    {
        var current = Fixtures.Expense();
        Assert.Equal("version_conflict", Assert.Throws<DomainException>(() => ExpenseService.Update(Fixtures.Group(), current, current, "ua", 0, Fixtures.Now)).Code);
        var deleted = ExpenseService.Delete(Fixtures.Group(), current, "ua", 1, Fixtures.Now);
        Assert.Equal("expense_deleted", Assert.Throws<DomainException>(() => ExpenseService.Delete(Fixtures.Group(), deleted, "ua", 2, Fixtures.Now)).Code);
        Assert.Equal("expense_deleted", Assert.Throws<DomainException>(() => ExpenseService.Update(Fixtures.Group(), deleted, current, "ua", 2, Fixtures.Now)).Code);
        Assert.Equal("expense_not_deleted", Assert.Throws<DomainException>(() => ExpenseService.Restore(Fixtures.Group(), current, "ua", 1, Fixtures.Now)).Code);
    }

    [Theory]
    [InlineData(-1, true)]
    [InlineData(0, true)]
    [InlineData(1, false)]
    public void RestoreBoundaryIsExactlyThirtyDays(long extraTicks, bool allowed)
    {
        var deleted = ExpenseService.Delete(Fixtures.Group(), Fixtures.Expense(), "ua", 1, Fixtures.Now);
        var restoreAt = Fixtures.Now.AddDays(30).AddTicks(extraTicks);
        if (allowed)
        {
            var restored = ExpenseService.Restore(Fixtures.Group(), deleted, "ua", 2, restoreAt);
            Assert.Null(restored.DeletedAt);
            Assert.Equal(3, restored.Version);
        }
        else Assert.Equal("restore_window_expired", Assert.Throws<DomainException>(() => ExpenseService.Restore(Fixtures.Group(), deleted, "ua", 2, restoreAt)).Code);
    }

    [Fact]
    public void ArchivedGroupsBlockExpenseMutation()
    {
        var group = Fixtures.Group() with { Archived = true };
        Assert.Equal("group_archived", Assert.Throws<DomainException>(() => ExpenseService.Create(group, Fixtures.Expense(), "ua", Fixtures.Now)).Code);
        Assert.Throws<DomainException>(() => ExpenseService.Delete(group, Fixtures.Expense(), "ua", 1, Fixtures.Now));
    }

    [Fact]
    public void AllocatedExpenseCapIncludesDeletedIds()
    {
        Assert.Equal("expense_limit", Assert.Throws<DomainException>(() => ExpenseService.Create(Fixtures.Group() with { ExpenseCount = 10000 },
            Fixtures.Expense(), "ua", Fixtures.Now)).Code);
    }
}
