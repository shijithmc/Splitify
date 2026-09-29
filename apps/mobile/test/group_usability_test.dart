import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/money.dart';
import 'package:hisaab/features/expense.dart';
import 'package:hisaab/features/group.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> loadBundledFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final family in ['Outfit', 'WorkSans']) {
      final loader = FontLoader(family);
      for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(rootBundle.load('assets/fonts/$family-$weight.ttf'));
      }
      await loader.load();
    }
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Group settlementGroup(
    Map<String, Map<String, int>> pairs, {
    bool organizer = true,
  }) => Group.from({
    'id': 'group',
    'name': 'Shared home',
    'type': 'Home',
    'version': 1,
    if (organizer) 'creatorId': 'user',
    'members': [
      {'id': 'me', 'displayName': 'You', 'userId': 'user'},
      {'id': 'alex', 'displayName': 'Alex', 'isPlaceholder': true},
      {'id': 'sam', 'displayName': 'Sam', 'isPlaceholder': true},
    ],
    'balances': [
      for (final entry in pairs.entries)
        {
          'participantId': entry.key,
          'netPaise': entry.value.values.fold<int>(0, (a, b) => a + b),
          'counterparties': entry.value,
        },
    ],
  });

  Future<void> openSettlement(WidgetTester tester, Group group) async {
    final controller = AppController()..user = {'id': 'user'};
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: SettlementPage(controller: controller, group: group),
      ),
    );
  }

  Finder personField(String label) =>
      find.widgetWithText(DropdownButtonFormField<String>, label);

  Future<void> showPerson(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      personField(label),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settlement defaults to the person who owes you', (tester) async {
    await openSettlement(
      tester,
      settlementGroup({
        'me': {'sam': 12500},
        'alex': {},
        'sam': {'me': -12500},
      }),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '125.00',
    );
    await showPerson(tester, 'Who paid?');
    final payer = tester.widget<DropdownButtonFormField<String>>(
      personField('Who paid?'),
    );
    expect(payer.initialValue, 'sam');
    final payers = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: personField('Who paid?'),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    expect(payers.items!.map((item) => item.value), ['sam']);
    await showPerson(tester, 'Who received?');
    final recipient = tester.widget<DropdownButtonFormField<String>>(
      personField('Who received?'),
    );
    expect(recipient.initialValue, 'me');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing payer selects their debt and updates the amount', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openSettlement(
      tester,
      settlementGroup({
        'me': {'alex': -10000},
        'alex': {'me': 10000, 'sam': -2500},
        'sam': {'alex': 2500},
      }),
    );
    await showPerson(tester, 'Who paid?');
    final payer = personField('Who paid?');
    await tester.ensureVisible(payer);
    await tester.pumpAndSettle();
    await tester.tap(payer);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alex').last);
    await tester.pumpAndSettle();
    await showPerson(tester, 'Who received?');
    final recipient = tester.widget<DropdownButtonFormField<String>>(
      personField('Who received?'),
    );
    expect(recipient.initialValue, 'sam');
    await tester.scrollUntilVisible(
      find.byType(TextField),
      -160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '25.00',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unrelated debts are not offered to regular group members', (
    tester,
  ) async {
    await openSettlement(
      tester,
      settlementGroup({
        'me': {},
        'alex': {'sam': -2500},
        'sam': {'alex': 2500},
      }, organizer: false),
    );
    expect(find.text('No payments for you to record'), findsOneWidget);
    expect(find.text('Everyone is settled up'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('settled groups explain why no payment is needed', (
    tester,
  ) async {
    await openSettlement(tester, settlementGroup({}));
    expect(find.text('Everyone is settled up'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Record payment'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('offsetting debts stay visible and expenses show your share', (
    tester,
  ) async {
    final controller = AppController();
    await controller.startDemo();
    final created = await controller.request('POST', '/groups', {
      'name': 'Offsetting debts',
      'type': 'Home',
    });
    final groupId = created['id'];
    final me = created['members'][0]['id'];
    final alex = (await controller.request('POST', '/groups/$groupId/members', {
      'displayName': 'Alex',
    }))['id'];
    final sam = (await controller.request('POST', '/groups/$groupId/members', {
      'displayName': 'Sam',
    }))['id'];
    for (final entry in [('lunch', me, alex), ('dinner', sam, sam)]) {
      await controller.request('POST', '/groups/$groupId/expenses', {
        'id': entry.$1,
        'description': entry.$1,
        'date': '2026-09-28',
        'amountPaise': 10000,
        'payerId': entry.$2,
        'mode': 'Equal',
        'participants': [
          {'participantId': me, 'value': 1},
          {'participantId': entry.$3, 'value': 1},
        ],
      });
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: GroupPage(controller: controller, groupId: groupId),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No net balance'), findsOneWidget);
    expect(find.text('You are settled up'), findsNothing);
    for (final description in ['lunch', 'dinner']) {
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(description),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      final expense = find
          .ancestor(of: find.text(description), matching: find.byType(InkWell))
          .first;
      expect(
        find.descendant(of: expense, matching: find.text('Your share ₹50.00')),
        findsOneWidget,
      );
      if (description == 'lunch') {
        expect(
          find.descendant(of: expense, matching: find.text('You lent ₹50.00')),
          findsOneWidget,
        );
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('add expense stays anchored from balances with larger text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = AppController();
    await controller.startDemo();
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: GroupPage(
          controller: controller,
          groupId: controller.groups.first.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final add = find.widgetWithText(FilledButton, 'Add expense');
    expect(add.hitTestable(), findsOneWidget);
    final balances = find.widgetWithText(ChoiceChip, 'Balances');
    await tester.scrollUntilVisible(
      balances,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(balances);
    await tester.pumpAndSettle();
    await tester.tap(balances);
    await tester.pumpAndSettle();
    expect(add.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.byType(ExpensePage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final display in [(390.0, 1.0), (320.0, 1.6)]) {
    testWidgets('large group balance stays whole at $display', (tester) async {
      await loadBundledFonts(tester);
      tester.view.physicalSize = Size(display.$1, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = display.$2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = AppController();
      await controller.startDemo();
      final created = await controller.request('POST', '/groups', {
        'name': 'Big trip',
        'type': 'Trip',
      });
      final groupId = created['id'];
      final me = created['members'][0]['id'];
      final alex = (await controller.request(
        'POST',
        '/groups/$groupId/members',
        {'displayName': 'Alex'},
      ))['id'];
      await controller.request('POST', '/groups/$groupId/expenses', {
        'id': 'large-expense',
        'description': 'Trip booking',
        'date': '2026-09-29',
        'amountPaise': maxAmountPaise,
        'payerId': me,
        'mode': 'Equal',
        'participants': [
          {'participantId': alex, 'value': 1},
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: HisaabTheme.light,
          home: GroupPage(controller: controller, groupId: groupId),
        ),
      );
      await tester.pumpAndSettle();
      final amount = find.byKey(const ValueKey('group-balance-amount'));
      final settle = find.widgetWithText(OutlinedButton, 'Settle up');
      await tester.scrollUntilVisible(
        settle,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(settle);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(amount).data, money(maxAmountPaise));
      final topLeft = tester.getTopLeft(amount);
      final bottomLeft = tester.getBottomLeft(amount);
      final bottomRight = tester.getBottomRight(amount);
      expect(topLeft.dx, greaterThanOrEqualTo(20));
      expect(bottomRight.dx, lessThanOrEqualTo(display.$1 - 20));
      expect(bottomLeft.dy - topLeft.dy, greaterThanOrEqualTo(28));
      expect(bottomLeft.dy, lessThan(tester.getTopLeft(settle).dy));
      expect(settle.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  testWidgets(
    'add-person sheet validates a name and stays usable above keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final controller = AppController();
      await controller.startDemo();
      final groupId = controller.groups.first.id;
      await tester.pumpWidget(
        MaterialApp(
          theme: HisaabTheme.light,
          home: GroupPage(controller: controller, groupId: groupId),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Group options'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Add person'));
      await tester.pumpAndSettle();
      final add = find.widgetWithText(FilledButton, 'Add person');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('Enter their name to add them.'), findsOneWidget);
      final name = find.widgetWithText(TextField, 'Name');
      await tester.ensureVisible(name);
      await tester.enterText(name, 'A new friend');
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(add.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.tap(add);
      await tester.pumpAndSettle();
      final group = Group.from(
        await controller.request('GET', '/groups/$groupId'),
      );
      expect(
        group.members.any((member) => member.name == 'A new friend'),
        isTrue,
      );
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('offline group options explain why changes are unavailable', (
    tester,
  ) async {
    final controller = _OfflineDemoController();
    await controller.startDemo();
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: GroupPage(
          controller: controller,
          groupId: controller.groups.first.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Add expense'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Group options'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Invite')).enabled,
      isFalse,
    );
    expect(
      find.text('Reconnect to make changes. Your saved history is still here.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

class _OfflineDemoController extends AppController {
  @override
  bool get offline => true;
}
