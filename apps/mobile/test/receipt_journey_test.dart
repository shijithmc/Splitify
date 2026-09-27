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
      expect(find.textContaining('Check this reading'), findsWidgets);
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
  testWidgets(
    'illustrated capture keeps the live allowance and safe actions at large text sizes',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      for (var i = 0; i < 2; i++) {
        final counted = await coordinator.create(group.id);
        counted['demoCounted'] = true;
        counted['status'] = 'attached';
      }
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
      expect(find.text('3 of 5 scans left this month'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Read bill'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Read bill'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(
                TextButton,
                'Enter manually with these photos',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      coordinator.dispose();
    },
  );
}
