import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/features/expense.dart';
import 'package:hisaab/features/group.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(AppController, Group)> fixture() async {
    final controller = AppController();
    await controller.startDemo();
    final group = Group.from(
      await controller.request('GET', '/groups/${controller.groups.first.id}'),
    );
    return (controller, group);
  }

  void compactDisplay(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  testWidgets('expense split methods remain reachable with larger text', (
    tester,
  ) async {
    compactDisplay(tester);
    final (controller, group) = await fixture();
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: ExpensePage(controller: controller, group: group),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'A shared lunch');
    final amount = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Total amount',
    );
    await tester.scrollUntilVisible(
      amount,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(amount, '100');
    tester.testTextInput.hide();
    for (final mode in ['Exact', 'Percentage', 'Shares', 'Equal']) {
      final chip = find.widgetWithText(ChoiceChip, mode);
      await tester.scrollUntilVisible(
        chip,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
      expect(tester.takeException(), isNull);
    }
    await tester.scrollUntilVisible(
      find.text('Every share, clear'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.scrollUntilVisible(
      find.text('₹33.34'),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('₹33.34'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Save expense'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save expense'),
    );
    expect(save.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('group activity tabs stay usable on a compact display', (
    tester,
  ) async {
    compactDisplay(tester);
    final (controller, group) = await fixture();
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: GroupPage(controller: controller, groupId: group.id),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final label in ['Balances', 'Payments', 'Expenses']) {
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      final chip = find.widgetWithText(ChoiceChip, label);
      await tester.scrollUntilVisible(
        chip,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('payment recording remains explicit and rejects overpayment', (
    tester,
  ) async {
    compactDisplay(tester);
    final (controller, group) = await fixture();
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: SettlementPage(controller: controller, group: group),
      ),
    );
    await tester.scrollUntilVisible(
      find.byType(TextField),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextField), '999999');
    tester.testTextInput.hide();
    const explanation =
        'Record a payment you have already made. Hisaab does not move money.';
    await tester.scrollUntilVisible(
      find.text(explanation),
      -160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(explanation), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Record payment'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Record payment'));
    await tester.pumpAndSettle();
    expect(
      find.text('Payment must not exceed the outstanding debt.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
