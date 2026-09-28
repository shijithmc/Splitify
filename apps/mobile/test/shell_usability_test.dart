import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/receipts.dart';
import 'package:hisaab/features/expense.dart';
import 'package:hisaab/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/receipt_fakes.dart';

class ShellTestController extends ReceiptTestController {
  bool forceOffline = false;
  @override
  bool get offline => forceOffline || super.offline;
}

Future<ShellTestController> demo(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final c = ShellTestController();
  await c.startDemo();
  c.receiptOverride = ReceiptCoordinator(
    repository: c.repository!,
    account: c.userId,
    current: () => c.signedIn,
    foreground: () => true,
    store: MemoryReceiptStore(),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    c.receiptOverride?.dispose();
    c.dispose();
  });
  return c;
}

Group summary(String name, String type, {bool archived = false}) => Group.from({
  'id': name,
  'name': name,
  'type': type,
  'version': 1,
  'memberCount': 2,
  'netPaise': 0,
  'archived': archived,
});

void main() {
  testWidgets('home add expense stays reachable on a small screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = await demo(tester);
    await tester.pumpWidget(HisaabApp(controller: c));
    expect(find.text('Add expense').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Add expense'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Goa, here we come'));
    await tester.pumpAndSettle();
    expect(find.byType(ExpensePage), findsOneWidget);
    expect(c.protectedDepth, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search combines with friend and archived filters', (
    tester,
  ) async {
    final c = await demo(tester);
    c.groups = [
      summary('Beach trip', 'Trip'),
      summary('Maya', 'Direct'),
      summary('Old home', 'Home', archived: true),
    ];
    c.tab = 1;
    await tester.pumpWidget(HisaabApp(controller: c));
    expect(find.text('Beach trip'), findsOneWidget);
    expect(find.text('Maya'), findsOneWidget);
    expect(find.text('Old home'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Friends'));
    await tester.pumpAndSettle();
    expect(find.text('Beach trip'), findsNothing);
    expect(find.text('Maya'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  MAYA  ');
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'missing');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Archived'));
    await tester.pumpAndSettle();
    expect(find.text('Old home'), findsOneWidget);
    expect(find.text('Maya'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offsetting debts are not described as settled', (tester) async {
    final c = await demo(tester);
    c.balances = {
      'netPaise': 0,
      'owedPaise': 10000,
      'owingPaise': 10000,
      'friends': [
        {'displayName': 'Maya', 'netPaise': 10000},
        {'displayName': 'Dev', 'netPaise': -10000},
      ],
    };
    await tester.pumpWidget(HisaabApp(controller: c));
    expect(find.text('Your balances cancel out overall'), findsOneWidget);
    expect(find.text('You’re all settled up'), findsNothing);
    expect(find.text('₹100.00'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('activity has quick expense entry and offline disables it', (
    tester,
  ) async {
    final c = await demo(tester);
    c.tab = 2;
    await tester.pumpWidget(HisaabApp(controller: c));
    expect(find.text('Add expense').hitTestable(), findsOneWidget);
    c.forceOffline = true;
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );
  });
}
