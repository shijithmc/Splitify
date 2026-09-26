import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('welcome offers an explicitly local demo', (tester) async {
    final controller = AppController()..loading = false;
    await tester.pumpWidget(HisaabApp(controller: controller));
    expect(find.text('Good times.\nClear tabs.'), findsOneWidget);
    expect(find.text('Explore the local demo →'), findsOneWidget);
  });
  testWidgets('demo has balances, groups and usable settings', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    await controller.startDemo();
    await tester.pumpWidget(HisaabApp(controller: controller));
    expect(find.text('DEMO'), findsOneWidget);
    expect(find.text('Goa, here we come'), findsOneWidget);
    expect(find.text('₹1,340.00'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Local demo · no real account'), findsOneWidget);
    expect(find.text('Expense updates'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('small display and large text stay scrollable', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = AppController()..loading = false;
    await tester.pumpWidget(HisaabApp(controller: controller));
    expect(tester.takeException(), isNull);
    SharedPreferences.setMockInitialValues({});
    await controller.startDemo();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('add expense previews conserved paise and saves to its group', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = AppController();
    await controller.startDemo();
    await tester.pumpWidget(HisaabApp(controller: controller));
    await tester.tap(find.text('Groups'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Goa, here we come'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add expense'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Test chai');
    await tester.enterText(find.byType(TextField).at(1), '100');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -650));
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
  });
}
