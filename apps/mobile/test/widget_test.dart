import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/main.dart';
import 'package:hisaab/core/receipts.dart';
import 'package:hisaab/features/receipts.dart';
import 'package:hisaab/features/group.dart';
import 'support/receipt_fakes.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('welcome offers an explicitly local demo', (tester) async {
    final controller = ReceiptTestController()..loading = false;
    await tester.pumpWidget(HisaabApp(controller: controller));
    expect(find.text('More memories.\nLess money talk.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Explore the local demo →'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Explore the local demo →'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets('system Back returns from a failed sign-in to welcome', (
    tester,
  ) async {
    final controller = ReceiptTestController()
      ..loading = false
      ..error = 'Sign-in could not finish.';
    await tester.pumpWidget(HisaabApp(controller: controller));
    expect(find.text('Continue with Google'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('More memories.\nLess money talk.'), findsOneWidget);
    expect(controller.error, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
  testWidgets(
    'Home quick actions open the chosen group and protect receipt flow',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReceiptTestController();
      await controller.startDemo();
      final receipts = ReceiptCoordinator(
        repository: controller.repository!,
        account: controller.userId,
        current: () => controller.signedIn,
        foreground: () => true,
        store: MemoryReceiptStore(),
      );
      controller.receiptOverride = receipts;
      await tester.pumpWidget(HisaabApp(controller: controller));
      await tester.scrollUntilVisible(
        find.text('Attach receipt'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(
        find.widgetWithText(TextButton, 'Attach receipt'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Attach receipt'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.widgetWithText(ListTile, 'Goa, here we come'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ReceiptCapturePage>(find.byType(ReceiptCapturePage))
            .group
            .name,
        'Goa, here we come',
      );
      expect(controller.protectedDepth, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(controller.protectedDepth, 0);
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Settle up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settle up'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.widgetWithText(ListTile, 'Goa, here we come'),
        ),
      );
      await tester.pumpAndSettle();
      final payment = tester.widget<SettlementPage>(
        find.byType(SettlementPage),
      );
      expect(payment.group.members, isNotEmpty);
      expect(payment.group.name, 'Goa, here we come');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      receipts.dispose();
      controller.dispose();
    },
  );
  testWidgets('demo has balances, groups and usable settings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = ReceiptTestController();
    await controller.startDemo();
    controller.receiptOverride = ReceiptCoordinator(
      repository: controller.repository!,
      account: controller.userId,
      current: () => controller.signedIn,
      foreground: () => true,
      store: MemoryReceiptStore(),
    );
    await tester.pumpWidget(HisaabApp(controller: controller));
    expect(find.text('DEMO'), findsOneWidget);
    expect(find.text('₹1,340.00'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Goa, here we come'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Goa, here we come'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Local demo · no real account'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Expense updates'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Expense updates'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.receiptOverride?.dispose();
    controller.dispose();
  });
  testWidgets('small display and large text stay scrollable', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = ReceiptTestController()..loading = false;
    await tester.pumpWidget(HisaabApp(controller: controller));
    expect(tester.takeException(), isNull);
    SharedPreferences.setMockInitialValues({});
    await controller.startDemo();
    controller.receiptOverride = ReceiptCoordinator(
      repository: controller.repository!,
      account: controller.userId,
      current: () => controller.signedIn,
      foreground: () => true,
      store: MemoryReceiptStore(),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.receiptOverride?.dispose();
    controller.dispose();
  });
  testWidgets(
    'calculator amount previews conserved paise and saves to its group',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = ReceiptTestController();
      await controller.startDemo();
      controller.receiptOverride = ReceiptCoordinator(
        repository: controller.repository!,
        account: controller.userId,
        current: () => controller.signedIn,
        foreground: () => true,
        store: MemoryReceiptStore(),
      );
      await tester.pumpWidget(HisaabApp(controller: controller));
      await tester.tap(find.text('Groups'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Goa, here we come'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add expense'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Test chai');
      await tester.scrollUntilVisible(
        find.byTooltip('Open calculator'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('Open calculator'));
      await tester.pumpAndSettle();
      expect(controller.protectedDepth, 3);
      await tester.enterText(
        find.byKey(const Key('calculator-expression')),
        '99 + 1',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Use ₹100.00'));
      await tester.tap(find.text('Use ₹100.00'));
      await tester.pumpAndSettle();
      expect(controller.protectedDepth, 2);
      await tester.scrollUntilVisible(
        find.text('₹33.34'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('₹33.34'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Save expense'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save expense'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Test chai'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Test chai'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.receiptOverride?.dispose();
      controller.dispose();
    },
  );
}
