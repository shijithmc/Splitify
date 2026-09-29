import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/core/money.dart';
import 'package:hisaab/core/spending_import.dart';
import 'package:hisaab/features/spending.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<AppController> spendingDemo(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final controller = AppController(
    spendingImports: SpendingImportService(android: false),
  );
  await controller.startDemo();
  await controller.spending.initialize();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  return controller;
}

Future<void> showSpending(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: HisaabTheme.light,
      home: SpendingPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cash expense validates and updates private spending', (
    tester,
  ) async {
    final controller = await spendingDemo(tester);
    final before = controller.spending.spendingPaise;
    await showSpending(tester, controller);
    await tester.scrollUntilVisible(
      find.text('Add cash expense'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Add cash expense'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save cash expense'));
    await tester.pumpAndSettle();
    expect(find.text('Give this payment a short name.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount'),
      '125.50',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'What was it for?'),
      'A quiet coffee',
    );
    await tester.ensureVisible(find.text('Save cash expense'));
    await tester.tap(find.text('Save cash expense'));
    await tester.pumpAndSettle();
    final transaction = controller.spending.transactions.firstWhere(
      (t) => t['title'] == 'A quiet coffee',
    );
    expect(transaction['amountPaise'], 12550);
    expect(transaction['source'], 'Cash');
    expect(controller.spending.spendingPaise, before + 12550);
    expect(tester.takeException(), isNull);
  });

  testWidgets('budget and payday edits recalculate the daily amount', (
    tester,
  ) async {
    final controller = await spendingDemo(tester);
    await controller.spending.clear();
    await showSpending(tester, controller);
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Your payday'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Day of month'),
      '32',
    );
    await tester.tap(find.text('Save payday'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a day from 1 to 31.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Day of month'),
      '28',
    );
    await tester.tap(find.text('Save payday'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add category budget'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Monthly limit'),
      '5000',
    );
    await tester.tap(find.text('Save budget'));
    await tester.pumpAndSettle();
    expect(controller.spending.payday, 28);
    expect(controller.spending.budgets['Food & cafés'], 500000);
    expect(
      controller.spending.dailyPaise,
      500000 ~/ controller.spending.daysToPayday!,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('transaction category changes apply to later merchant payments', (
    tester,
  ) async {
    final controller = await spendingDemo(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: SpendingTransactionPage(
          controller: controller,
          transactionId: 'demo-lunch',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Category'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(
      controller.spending.transactions.firstWhere(
        (t) => t['id'] == 'demo-lunch',
      )['category'],
      'Groceries',
    );
    await controller.spending.importRows([
      {
        'title': 'Beachside lunch',
        'amountPaise': 5000,
        'date': day(DateTime.now()),
        'category': 'Food & cafés',
        'source': 'Statement',
      },
    ]);
    expect(
      controller.spending.transactions
          .where((t) => t['title'] == 'Beachside lunch')
          .every((t) => t['category'] == 'Groceries'),
      isTrue,
    );
    await tester.scrollUntilVisible(
      find.text('Exclude from budgets'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exclude from budgets'));
    await tester.pumpAndSettle();
    expect(
      controller.spending.transactions.firstWhere(
        (t) => t['id'] == 'demo-lunch',
      )['excluded'],
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('private page hides transaction data when the account changes', (
    tester,
  ) async {
    final controller = await spendingDemo(tester);
    await showSpending(tester, controller);
    expect(find.byKey(const Key('spending-daily-budget')), findsOneWidget);
    controller.user = {'id': 'another-account'};
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Sign in again to see your spending.'), findsOneWidget);
    expect(find.byKey(const Key('spending-daily-budget')), findsNothing);
    expect(find.text('Beachside lunch'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changed group expenses replace stale share copy with a review notice',
    (tester) async {
      final controller = await spendingDemo(tester);
      await controller.spending.update('demo-lunch', {
        'groupId': 'unavailable-group',
        'expenseId': 'old-expense',
        'sharePaise': 42000,
        'linkNeedsReview': true,
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: HisaabTheme.light,
          home: SpendingTransactionPage(
            controller: controller,
            transactionId: 'demo-lunch',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Review this shared payment'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(
          'Group expense changed. Full payment counted until reviewed.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Your budget counts ₹420'), findsNothing);
      expect(find.text('View group'), findsOneWidget);
      await showSpending(tester, controller);
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Group expense changed · review needed'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Your share ₹420'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('spending screens support 320dp, large text and large amounts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = await spendingDemo(tester);
    await controller.spending.setBudget('Food & cafés', maxAmountPaise);
    await controller.spending.setBudget('Shopping', maxAmountPaise);
    await controller.spending.update('demo-lunch', {
      'amountPaise': maxAmountPaise,
    });
    await showSpending(tester, controller);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: SpendingPage(key: UniqueKey(), controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Budgets'));
    await tester.tap(find.text('Budgets'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Add category budget'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Add cash expense'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: SpendingTransactionPage(
          controller: controller,
          transactionId: 'demo-lunch',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Exclude from budgets'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [SpendingHomeCard(controller: controller)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('View spending'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reviewed refund counts only the personal amount', (
    tester,
  ) async {
    final controller = await spendingDemo(tester);
    await controller.spending.clear();
    await controller.spending.add({
      'id': 'shared-lunch-refund',
      'title': 'Beachside lunch refund',
      'amountPaise': 126000,
      'date': day(DateTime.now()),
      'category': 'Food & cafés',
      'kind': 'refund',
      'source': 'Statement',
    });
    expect(controller.spending.spendingPaise, 0);
    await showSpending(tester, controller);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Refund · Needs review'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: SpendingTransactionPage(
          controller: controller,
          transactionId: 'shared-lunch-refund',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Set personal refund'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set personal refund'));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Personal refund amount');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await tester.enterText(field, '1260.01');
    await tester.tap(find.text('Save personal refund'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an amount from ₹0 to ₹1,260.'), findsOneWidget);
    await tester.enterText(field, '420');
    await tester.tap(find.text('Save personal refund'));
    await tester.pumpAndSettle();
    expect(controller.spending.transactions.single['refundBudgetPaise'], 42000);
    expect(controller.spending.spendingPaise, -42000);
    expect(find.text('Personal refund ₹420'), findsOneWidget);
    await showSpending(tester, controller);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Personal refund ₹420'), findsOneWidget);
    expect(find.text('Refund · Needs review'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large-text sharing preview can choose a group and adjust people',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = await spendingDemo(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: HisaabTheme.light,
          home: SpendingTransactionPage(
            controller: controller,
            transactionId: 'demo-lunch',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Add to a group'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to a group'));
      // The payment page's busy indicator animates behind the group picker.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Choose your group'), findsOneWidget);
      expect(find.text('Goa, here we come').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Goa, here we come'));
      await tester.pumpAndSettle();
      expect(find.text('A little check before sharing.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Split equally · 3 people'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Split equally · 3 people'), findsOneWidget);
      final other = controller.groups
          .firstWhere((group) => group.name == 'Goa, here we come')
          .members
          .firstWhere((member) => member.userId != controller.userId);
      final person = find.widgetWithText(CheckboxListTile, other.name);
      await tester.scrollUntilVisible(
        person,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(person);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(person).value, isTrue);
      await tester.tap(find.text(other.name));
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(person).value, isFalse);
      await tester.scrollUntilVisible(
        find.text('Your budget counts ₹630.00'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Your budget counts ₹630.00'), findsOneWidget);
      final row = controller.spending.transactions.firstWhere(
        (row) => row['id'] == 'demo-lunch',
      );
      expect(row['expenseId'], isNull);
      expect(row['pendingShare'], isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
