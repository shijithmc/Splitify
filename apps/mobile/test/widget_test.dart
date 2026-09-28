import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/main.dart';
import 'package:hisaab/core/receipts.dart';
import 'package:hisaab/core/money.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/features/shell.dart';
import 'package:hisaab/features/receipts.dart';
import 'package:hisaab/features/group.dart';
import 'support/receipt_fakes.dart';
import 'package:shared_preferences/shared_preferences.dart';

class InviteTestController extends ReceiptTestController {
  Json? acceptedInvite;

  @override
  Future<Json> request(String method, String path, [Json? data]) async {
    if (method == 'POST' && path == '/invites/accept') {
      acceptedInvite = data;
      throw ApiFailure('Invitation expired. Ask your friend for a new link.');
    }
    return super.request(method, path, data);
  }
}

void main() {
  testWidgets('welcome offers an explicitly local demo', (tester) async {
    final controller = ReceiptTestController()..loading = false;
    await tester.pumpWidget(HisaabApp(controller: controller));
    expect(find.text('Good times.\nShared fairly.'), findsOneWidget);
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
    expect(find.text('Good times.\nShared fairly.'), findsOneWidget);
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
      await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, 'Settle up'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
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
    expect(find.text('You are owed'), findsOneWidget);
    expect(find.text(money(controller.balances['owedPaise'])), findsOneWidget);
    expect(find.text('You owe'), findsOneWidget);
    expect(find.text(money(controller.balances['owingPaise'])), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Goa, here we come'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Goa, here we come'), findsOneWidget);
    await tester.tap(find.text('Account'));
    await tester.pumpAndSettle();
    expect(find.text('Local demo · no real account'), findsOneWidget);
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
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
  testWidgets(
    'creating a friend preserves the direct group and placeholder member',
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
      await tester.tap(find.text('New'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Create group'));
      await tester.pumpAndSettle();
      expect(find.text('Give your group a name.'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('group-type-Direct')),
      );
      await tester.tap(find.byKey(const ValueKey('group-type-Direct')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '  Maya Test  ');
      await tester.tap(find.widgetWithText(FilledButton, 'Add friend'));
      await tester.pumpAndSettle();
      final group = controller.groups.singleWhere(
        (group) => group.name == 'Maya Test',
      );
      expect(group.type, 'Direct');
      final detail = Group.from(
        await controller.request('GET', '/groups/${group.id}'),
      );
      expect(detail.members, hasLength(2));
      final friend = detail.members.singleWhere(
        (member) => member.name == 'Maya Test',
      );
      expect(friend.placeholder, isTrue);
      expect(friend.userId, isNull);
      expect(find.byType(GroupPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.receiptOverride?.dispose();
      controller.dispose();
    },
  );

  testWidgets(
    'joining validates empty URLs and reviews member history before accepting',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final controller = InviteTestController();
      await controller.startDemo();
      await tester.pumpWidget(HisaabApp(controller: controller));
      await tester.tap(find.byTooltip('Join an invitation'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('invitation-link')),
        'https://example.com',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Review invitation'));
      await tester.pumpAndSettle();
      expect(
        find.text('Paste a complete invitation link or token.'),
        findsOneWidget,
      );
      expect(controller.acceptedInvite, isNull);
      await tester.enterText(
        find.byKey(const Key('invitation-link')),
        'https://example.com/invite/?token=friend-token',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Review invitation'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'you’ll claim that member’s expense history and balances',
        ),
        findsOneWidget,
      );
      expect(controller.acceptedInvite, isNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Accept invitation'));
      await tester.pumpAndSettle();
      expect(controller.acceptedInvite, {'token': 'friend-token'});
      expect(
        find.text('Invitation expired. Ask your friend for a new link.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('new group action stays above the keyboard with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = ReceiptTestController();
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => createGroup(context, controller),
              child: const Text('Open new group'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open new group'));
    await tester.pumpAndSettle();
    final action = find.widgetWithText(FilledButton, 'Create group');
    expect(tester.getBottomLeft(action).dy, lessThanOrEqualTo(368));
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(find.text('Give your group a name.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
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
