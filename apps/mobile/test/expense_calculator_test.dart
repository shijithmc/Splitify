import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/features/expense_calculator.dart';

Future<void> openCalculator(
  WidgetTester tester, {
  String initialAmount = '',
  ValueChanged<int?>? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: HisaabTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                final result = await Navigator.of(context).push<int>(
                  MaterialPageRoute(
                    builder: (_) =>
                        ExpenseCalculatorPage(initialAmount: initialAmount),
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('Open calculator'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open calculator'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the initial amount and returns its paise on use', (
    tester,
  ) async {
    int? returned;
    await openCalculator(
      tester,
      initialAmount: '245.50',
      onResult: (value) => returned = value,
    );
    expect(find.text('₹245.50'), findsOneWidget);
    expect(find.text('Use ₹245.50'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('calculator-use')));
    await tester.tap(find.byKey(const Key('calculator-use')));
    await tester.pumpAndSettle();
    expect(returned, 24550);
    expect(find.text('Open calculator'), findsOneWidget);
  });

  testWidgets('back cancels without returning an amount', (tester) async {
    var completed = false;
    int? returned = 123;
    await openCalculator(
      tester,
      initialAmount: '245.50',
      onResult: (value) {
        completed = true;
        returned = value;
      },
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(returned, isNull);
  });

  testWidgets(
    'invalid or incomplete edits disable use and recover when fixed',
    (tester) async {
      await openCalculator(tester);
      final input = find.byKey(const Key('calculator-expression'));
      final use = find.byKey(const Key('calculator-use'));
      expect(tester.widget<FilledButton>(use).onPressed, isNull);
      for (final expression in ['1 / 0', '1 +', '1 - 2', '0.004']) {
        await tester.enterText(input, expression);
        await tester.pump();
        expect(tester.widget<FilledButton>(use).onPressed, isNull);
      }
      await tester.enterText(input, '240 + 60 ÷ 2');
      await tester.pump();
      expect(find.text('Use ₹270.00'), findsOneWidget);
      expect(tester.widget<FilledButton>(use).onPressed, isNotNull);
      await tester.enterText(input, '1.005');
      await tester.pump();
      expect(find.text('Use ₹1.01'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keypad respects the editing selection and can delete or clear', (
    tester,
  ) async {
    await openCalculator(tester, initialAmount: '245.50');
    final input = find.byKey(const Key('calculator-expression'));
    final controller = tester.widget<TextField>(input).controller!;
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('calculator-key-7')));
    await tester.tap(find.byKey(const Key('calculator-key-7')));
    await tester.pump();
    expect(controller.text, '7.50');
    controller.selection = const TextSelection.collapsed(offset: 4);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('calculator-key-⌫')));
    await tester.tap(find.byKey(const Key('calculator-key-⌫')));
    await tester.pump();
    expect(controller.text, '7.5');
    await tester.ensureVisible(find.text('Clear'));
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('calculator-use')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('narrow screens and large text can scroll to usable controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    int? returned;
    await openCalculator(
      tester,
      initialAmount: '245.50',
      onResult: (value) => returned = value,
    );
    final add = find.byKey(const Key('calculator-key-+'));
    await tester.ensureVisible(add);
    await tester.pump();
    final keySize = tester.getSize(add);
    expect(keySize.width, greaterThanOrEqualTo(44));
    expect(keySize.height, greaterThanOrEqualTo(44));
    final use = find.byKey(const Key('calculator-use'));
    await tester.ensureVisible(use);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(use);
    await tester.pumpAndSettle();
    expect(returned, 24550);
  });
}
