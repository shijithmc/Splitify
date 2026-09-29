import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/core/native_services.dart';
import 'package:hisaab/features/settings.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AnnualPriceBilling extends BillingService {
  @override
  bool readyFor(String expected) => expected == 'test-account';
  @override
  Future<List<Package>> packages(String expected) async => const [
    Package(
      'yearly',
      PackageType.annual,
      StoreProduct('annual', 'Ad-free', 'Yearly', 349, '₹349.00', 'INR'),
      PresentedOfferingContext('main', null, null),
    ),
  ];
}

Future<void> showPlan(WidgetTester tester, AppController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: HisaabTheme.light,
      home: PremiumPage(controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('annual plan uses store price and retains purchase safeguards', (
    tester,
  ) async {
    final controller = AppController(billing: AnnualPriceBilling())
      ..user = {'id': 'test-account'};
    await showPlan(tester, controller);
    await tester.scrollUntilVisible(
      find.text('Choose yearly'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('₹349.00 / year', findRichText: true), findsOneWidget);
    expect(find.textContaining('₹299'), findsNothing);
    // Legal URLs are absent in this test build, so checkout stays disabled.
    final purchase = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Choose yearly'),
    );
    expect(purchase.onPressed, isNull);
    expect(find.textContaining('Lifetime'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('pending purchase is distinguished from verified plan access', (
    tester,
  ) async {
    final controller = AppController()
      ..provisionalUntil = DateTime.now().add(const Duration(hours: 1));
    await showPlan(tester, controller);
    expect(find.text('Store verification pending'), findsOneWidget);
    expect(find.text('Ad-free is active'), findsNothing);
    expect(
      find.textContaining(
        'Ads are paused while your store purchase is verified.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'settings has no scan allowance and remains usable with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({});
      final controller = AppController();
      await controller.startDemo();
      controller.user['displayName'] = '';
      await tester.pumpWidget(
        MaterialApp(
          theme: HisaabTheme.light,
          home: Scaffold(body: SettingsPage(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('scans left'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Personal spending'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Personal spending').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Personal spending'));
      await tester.pumpAndSettle();
      expect(find.text('Your spending'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Notifications'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      // The final ensureVisible jump needs a frame to lay out the tall card.
      await tester.pumpAndSettle();
      expect(find.text('Notifications').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();
      expect(find.text('Stay in the loop'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Receipt details on lock screen'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final receiptPreference = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Receipt details on lock screen'),
      );
      expect(receiptPreference.value, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Privacy & your data'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Privacy & your data').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Privacy & your data'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Reset demo data'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Reset demo data'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('account preferences and deletion choices are reachable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    await controller.startDemo();
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: Scaffold(body: SettingsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsNothing);
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Expense updates'));
    await tester.pumpAndSettle();
    expect(controller.preferences['expenses'], isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(SwitchListTile, 'Expense updates'),
          )
          .value,
      isFalse,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Privacy & your data'));
    await tester.tap(find.text('Privacy & your data'));
    await tester.pumpAndSettle();
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Terms of use'), findsOneWidget);
    await tester.ensureVisible(find.text('Reset demo data'));
    await tester.tap(find.text('Reset demo data'));
    await tester.pumpAndSettle();
    expect(find.text('Manage store subscription'), findsOneWidget);
    await tester.ensureVisible(find.text('Keep account'));
    await tester.tap(find.text('Keep account'));
    await tester.pumpAndSettle();
    expect(controller.repository, isNotNull);
    expect(controller.demo, isTrue);
    expect(find.text('Reset the demo?'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('demo plan stays readable at narrow width and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    await controller.startDemo();
    await showPlan(tester, controller);
    await tester.scrollUntilVisible(
      find.text('How annual billing works'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('How annual billing works'), findsOneWidget);
    expect(find.text('Choose yearly'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
