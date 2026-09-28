import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/money.dart';
import 'package:hisaab/features/expense.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(AppController, Group)> openExpense(
    WidgetTester tester, {
    Expense? expense,
    AppController? existingController,
    Group? existingGroup,
  }) async {
    final controller = existingController ?? AppController();
    if (existingController == null) {
      await controller.startDemo();
      addTearDown(controller.dispose);
    }
    final group =
        existingGroup ??
        Group.from(
          await controller.request(
            'GET',
            '/groups/${controller.groups.first.id}',
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ExpensePage(
                    controller: controller,
                    group: group,
                    expense: expense,
                  ),
                ),
              ),
              child: const Text('Open expense'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open expense'));
    await tester.pumpAndSettle();
    return (controller, group);
  }

  Future<void> enterAmount(WidgetTester tester, String value) async {
    final amount = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Total amount',
    );
    await tester.ensureVisible(amount);
    await tester.enterText(amount, value);
    await tester.pumpAndSettle();
  }

  final save = find.widgetWithText(FilledButton, 'Save expense');

  testWidgets(
    'default equal expense saves above the keyboard on a small screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (controller, group) = await openExpense(tester);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.enterText(find.byType(TextField).first, 'Shared lunch');
      await enterAmount(tester, '100');
      tester.view.viewInsets = const FakeViewPadding(bottom: 230);
      await tester.pumpAndSettle();

      expect(find.text('Paid by you · split equally'), findsOneWidget);
      expect(save.hitTestable(), findsOneWidget);
      expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(338));
      expect(tester.takeException(), isNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Open expense'), findsOneWidget);
      final expenses = rows(
        (await controller.request(
          'GET',
          '/groups/${group.id}/expenses',
        ))['items'],
      );
      final saved = Expense(
        expenses.singleWhere((e) => e['description'] == 'Shared lunch'),
      );
      expect(saved.amount, 10000);
      expect(saved.mode, 'Equal');
      expect(saved.payer, group.participant(controller.userId));
      expect(saved.shares.length, 3);
      expect(saved.shares.values.reduce((a, b) => a + b), 10000);
    },
  );

  testWidgets('equal split can exclude a person before saving', (tester) async {
    final (controller, group) = await openExpense(tester);
    await tester.enterText(find.byType(TextField).first, 'Dinner for two');
    await enterAmount(tester, '100');
    tester.testTextInput.hide();
    final people = find.text('Split equally · 3 people');
    await tester.scrollUntilVisible(
      people,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(people);
    await tester.pumpAndSettle();
    final excluded = group.members.last;
    final checkbox = find.widgetWithText(CheckboxListTile, excluded.name);
    await tester.scrollUntilVisible(
      checkbox,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(find.text('Split equally · 2 people'), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final expenses = rows(
      (await controller.request(
        'GET',
        '/groups/${group.id}/expenses',
      ))['items'],
    );
    final saved = Expense(
      expenses.singleWhere((e) => e['description'] == 'Dinner for two'),
    );
    expect(saved.shares.containsKey(excluded.id), isFalse);
    expect(saved.shares.values, everyElement(5000));
    expect(saved.shares.length, 2);
  });

  testWidgets('tapping the current split method preserves edited allocations', (
    tester,
  ) async {
    final controller = AppController();
    addTearDown(controller.dispose);
    await controller.startDemo();
    final group = Group.from(
      await controller.request('GET', '/groups/${controller.groups.first.id}'),
    );
    final original = Expense(
      await controller.request('POST', '/groups/${group.id}/expenses', {
        'id': 'edit-exact-expense',
        'description': 'Different portions',
        'amountPaise': 10000,
        'date': day(DateTime.now()),
        'payerId': group.participant(controller.userId),
        'mode': 'Exact',
        'participants': [
          {'participantId': group.members[0].id, 'value': 2500},
          {'participantId': group.members[1].id, 'value': 7500},
        ],
      }),
    );
    await openExpense(
      tester,
      expense: original,
      existingController: controller,
      existingGroup: group,
    );
    final exact = find.widgetWithText(ChoiceChip, 'Exact');
    await tester.scrollUntilVisible(
      exact,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(exact);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final saved = Expense(
      await controller.request(
        'GET',
        '/groups/${group.id}/expenses/${original.id}',
      ),
    );
    expect(saved.shares, original.shares);
    expect(saved.mode, 'Exact');
    expect(saved.version, original.version + 1);
    expect(tester.takeException(), isNull);
  });
}
