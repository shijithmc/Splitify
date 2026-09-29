import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/money.dart';
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
  testWidgets('large home balances remain readable with 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.runAsync(() async {
      for (final family in ['Outfit', 'WorkSans']) {
        final loader = FontLoader(family);
        for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
          loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
        }
        await loader.load();
      }
    });
    final c = await demo(tester);
    c.balances = {
      'netPaise': 0,
      'owedPaise': maxAmountPaise,
      'owingPaise': maxAmountPaise,
      'friends': [],
    };
    await tester.pumpWidget(HisaabApp(controller: c));
    final owed = find.byKey(const ValueKey('home-balance-You are owed'));
    final owing = find.byKey(const ValueKey('home-balance-You owe'));
    await tester.scrollUntilVisible(
      owed,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.getBottomLeft(owed).dy,
      lessThan(tester.getTopLeft(owing).dy),
    );
    for (final amount in [owed, owing]) {
      final text = tester.widget<Text>(amount);
      expect(text.data, money(maxAmountPaise));
      final box = tester.renderObject<RenderBox>(amount);
      final origin = box.localToGlobal(Offset.zero);
      final fontEnd = box.localToGlobal(Offset(0, text.style!.fontSize! * 2));
      expect(fontEnd.dy - origin.dy, greaterThanOrEqualTo(24));
      expect(origin.dx, greaterThanOrEqualTo(38));
      expect(tester.getBottomRight(amount).dx, lessThanOrEqualTo(282.01));
    }
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    c.balances = {
      'netPaise': 134000,
      'owedPaise': 196000,
      'owingPaise': 62000,
      'friends': [],
    };
    c.notifyListeners();
    await tester.pumpAndSettle();
    // Resizing preserves the previous scroll offset; bring the now-shorter
    // balance card back into the lazy viewport before measuring its layout.
    await tester.scrollUntilVisible(
      owed,
      -120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(owed).dy,
      closeTo(tester.getTopLeft(owing).dy, .01),
    );
    expect(tester.getTopLeft(owed).dx, lessThan(tester.getTopLeft(owing).dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expense dock stays below scrolling content on each main tab',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await demo(tester);
      await tester.pumpWidget(HisaabApp(controller: c));
      for (final tab in [0, 1, 2]) {
        c.selectTab(tab);
        await tester.pumpAndSettle();
        final dock = tester.getRect(find.byKey(const Key('expense-dock')));
        expect(
          tester.getRect(find.byType(RefreshIndicator)).bottom,
          lessThanOrEqualTo(dock.top),
        );
        expect(find.text('Add expense').hitTestable(), findsOneWidget);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -240));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byType(RefreshIndicator)).bottom,
          lessThanOrEqualTo(dock.top),
        );
      }
      c.selectTab(3);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('expense-dock')), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.iOS,
      TargetPlatform.android,
    }),
  );

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
    await tester.tap(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.widgetWithText(ListTile, 'Goa, here we come'),
      ),
    );
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

  testWidgets('archived-only accounts retain outstanding totals and history', (
    tester,
  ) async {
    final c = await demo(tester);
    c.groups = [summary('Old home', 'Home', archived: true)];
    c.balances = {
      'netPaise': 12300,
      'owedPaise': 15000,
      'owingPaise': 2700,
      'friends': [],
    };
    await tester.pumpWidget(HisaabApp(controller: c));
    expect(find.text('₹150.00'), findsOneWidget);
    expect(find.text('₹27.00'), findsOneWidget);
    expect(find.text('Your next shared moment starts here.'), findsNothing);
    expect(find.text('Settle up'), findsNothing);
    await tester.tap(find.text('View balances'));
    await tester.pumpAndSettle();
    expect(find.text('Old home'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Archived'))
          .selected,
      isTrue,
    );
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
