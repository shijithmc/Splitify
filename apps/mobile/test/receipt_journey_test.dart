import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/receipts.dart';
import 'package:hisaab/features/receipts.dart';
import 'package:hisaab/features/shared.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/receipt_fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets(
    'sample bill review stays ad-protected, saves once and preserves a shared receipt',
    (tester) async {
      final controller = ReceiptTestController();
      await controller.startDemo();
      final group = Group.from(
        await controller.request(
          'GET',
          '/groups/${controller.groups.first.id}',
        ),
      );
      final store = MemoryReceiptStore();
      final coordinator = ReceiptCoordinator(
        repository: controller.repository!,
        account: controller.userId,
        current: () => controller.signedIn,
        foreground: () => true,
        store: store,
      );
      controller.receiptOverride = coordinator;
      final draft = await coordinator.sample(
        group.id,
        group.members.map((m) => m.id).toList(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => openPage(
                  context,
                  controller,
                  ReceiptReviewPage(
                    controller: controller,
                    group: group,
                    draft: draft,
                  ),
                ),
                child: const Text('Review sample'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review sample'));
      await tester.pumpAndSettle();
      expect(controller.protectedDepth, 1);
      expect(find.text('Check it. Then split it.'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Lime soda × 2'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Check this reading'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Calculate & check split'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Calculate & check split'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Confirm & save expense'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Confirm & save expense'));
      await tester.pumpAndSettle();
      expect(controller.protectedDepth, 0);
      final records = rows(
        (await controller.request(
          'GET',
          '/groups/${group.id}/expenses',
        ))['items'],
      );
      final saved = records.singleWhere((e) => e['id'] == draft['expenseId']);
      expect(saved['receiptId'], draft['id']);
      expect(saved['displaySplitKind'], 'Items');
      expect(
        object(
          saved['shares'],
        ).values.fold<int>(0, (sum, value) => sum + (value as int)),
        86100,
      );
      expect(draft['status'], 'attached');
      expect(rows((await coordinator.get(draft['id']))['media']), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      coordinator.dispose();
    },
  );
  testWidgets(
    'changing a reviewed field clears acknowledgement and account switching hides the draft',
    (tester) async {
      final controller = ReceiptTestController();
      await controller.startDemo();
      final group = Group.from(
        await controller.request(
          'GET',
          '/groups/${controller.groups.first.id}',
        ),
      );
      final coordinator = ReceiptCoordinator(
        repository: controller.repository!,
        account: controller.userId,
        current: () => controller.signedIn,
        foreground: () => true,
        store: MemoryReceiptStore(),
      );
      controller.receiptOverride = coordinator;
      final draft = await coordinator.sample(
        group.id,
        group.members.map((m) => m.id).toList(),
      );
      draft['review']['differenceAcknowledged'] = true;
      draft['review']['acknowledgedReviewHash'] = 'prior-hash';
      await tester.pumpWidget(
        MaterialApp(
          home: ReceiptReviewPage(
            controller: controller,
            group: group,
            draft: draft,
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Merchant / description'),
        'Corrected merchant',
      );
      await tester.pump();
      expect(draft['review']['differenceAcknowledged'], isFalse);
      expect(draft['review']['acknowledgedReviewHash'], isNull);
      controller.user = {'id': 'other-account'};
      controller.selectTab(0);
      await tester.pump();
      expect(find.textContaining('Receipt hidden.'), findsOneWidget);
      expect(find.text('Corrected merchant'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      coordinator.dispose();
    },
  );
  testWidgets('manual receipt attachment stays usable at large text sizes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ReceiptTestController();
    await controller.startDemo();
    final group = Group.from(
      await controller.request('GET', '/groups/${controller.groups.first.id}'),
    );
    final coordinator = ReceiptCoordinator(
      repository: controller.repository!,
      account: controller.userId,
      current: () => controller.signedIn,
      foreground: () => true,
      store: MemoryReceiptStore(),
    );
    controller.receiptOverride = coordinator;
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: ReceiptCapturePage(controller: controller, group: group),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('scans left'), findsNothing);
    expect(find.text('Read bill'), findsNothing);
    expect(find.text('Allow Google AI to read this bill'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Attach photos & enter details'),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Attach photos & enter details'),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    coordinator.dispose();
  });

  testWidgets('receipt editor sheets keep manual amounts and assignments', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ReceiptTestController();
    await controller.startDemo();
    final group = Group.from(
      await controller.request('GET', '/groups/${controller.groups.first.id}'),
    );
    final coordinator = ReceiptCoordinator(
      repository: controller.repository!,
      account: controller.userId,
      current: () => controller.signedIn,
      foreground: () => true,
      store: MemoryReceiptStore(),
    );
    controller.receiptOverride = coordinator;
    final draft = await coordinator.sample(
      group.id,
      group.members.map((member) => member.id).toList(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: ReceiptReviewPage(
          controller: controller,
          group: group,
          draft: draft,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Add item'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    Future<void> enter(String label, String value) async {
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
    }

    await enter('Original item name', 'Shared dessert');
    await enter('Quantity', '2');
    await enter('Unit price (INR)', '75');
    await enter('Line total (INR)', '150');
    tester.testTextInput.hide();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    final item = rows(draft['review']['items']).last;
    expect(item['name'], 'Shared dessert');
    expect(item['quantity'], '2');
    expect(item['unitPricePaise'], 7500);
    expect(item['lineTotalPaise'], 15000);
    await tester.scrollUntilVisible(
      find.text('Unassigned — choose who shared this'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Unassigned — choose who shared this'));
    await tester.pumpAndSettle();
    expect(find.text('Who shared Shared dessert?'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(CheckboxListTile, group.members.first.name),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(rows(draft['review']['items']).last['assigneeIds'], [
      group.members.first.id,
    ]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    coordinator.dispose();
    controller.dispose();
  });

  testWidgets('review save stays above keyboard and shows errors at the top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = ReceiptTestController();
    await controller.startDemo();
    final group = Group.from(
      await controller.request('GET', '/groups/${controller.groups.first.id}'),
    );
    final coordinator = ReceiptCoordinator(
      repository: controller.repository!,
      account: controller.userId,
      current: () => controller.signedIn,
      foreground: () => true,
      store: MemoryReceiptStore(),
    );
    controller.receiptOverride = coordinator;
    final draft = await coordinator.sample(
      group.id,
      group.members.map((member) => member.id).toList(),
    );
    draft['review']['grandTotalPaise'] += 1000;
    draft['preview'] = await coordinator.preview(draft);
    expect(draft['preview']['requiresDifferenceAcknowledgement'], isTrue);
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: ReceiptReviewPage(
          controller: controller,
          group: group,
          draft: draft,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Confirm & save expense');
    final merchant = find.widgetWithText(
      TextFormField,
      'Merchant / description',
    );
    await tester.scrollUntilVisible(
      merchant,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.showKeyboard(merchant);
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pumpAndSettle();
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(348));
    expect(tester.takeException(), isNull);
    tester.view.resetViewInsets();
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('Looks right?').hitTestable(), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    final error = find.text('Confirm the difference or correct the amounts.');
    expect(error.hitTestable(), findsOneWidget);
    expect(
      tester.getBottomRight(error).dy,
      lessThan(tester.getTopLeft(save).dy),
    );
    expect(draft['status'], isNot('attached'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    coordinator.dispose();
    controller.dispose();
  });
}
