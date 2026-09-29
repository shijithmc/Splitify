import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/spending.dart';
import 'package:hisaab/core/spending_store.dart';

class MemorySpendingStore extends SpendingStore {
  Json? value;
  bool fail = false, closed = false;
  Completer<Json?>? pendingLoad;
  Completer<void>? pendingSave;
  MemorySpendingStore([super.account = 'alice']);

  @override
  Future<Json?> load() async =>
      pendingLoad == null ? value : await pendingLoad!.future;
  @override
  Future<void> save(Json input) async {
    if (pendingSave != null) await pendingSave!.future;
    if (fail || closed) throw StateError('write failed');
    value = object(jsonDecode(jsonEncode(input)));
  }

  @override
  Future<void> close({bool delete = false}) async {
    closed = true;
    if (delete) value = null;
  }
}

Json payment({
  String id = 'one',
  String title = 'Coffee shop',
  int amount = 12500,
  String date = '2026-09-15T09:00:00.000Z',
  String kind = 'debit',
  String source = 'Manual',
  String category = 'Food & cafés',
}) => {
  'id': id,
  'title': title,
  'amountPaise': amount,
  'date': date,
  'kind': kind,
  'source': source,
  'category': category,
};

Json pendingShare(int amount) => {
  'groupId': 'group',
  'expenseId': 'expense-one',
  'payload': {
    'id': 'expense-one',
    'description': 'Lunch',
    'amountPaise': amount,
    'date': '2026-09-15',
    'payerId': 'alice',
    'mode': 'Equal',
    'participants': [
      {'participantId': 'alice', 'value': 1},
      {'participantId': 'bob', 'value': 1},
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final september = DateTime(2026, 9, 15, 12);
  SpendingController controller({MemorySpendingStore? store, DateTime? now}) =>
      SpendingController(
        account: 'alice',
        store: store ?? MemorySpendingStore(),
        clock: () => now ?? september,
      );

  test(
    'real accounts start empty; demo totals are explicit and monthly',
    () async {
      final real = controller();
      await real.initialize();
      expect(real.loaded, isTrue);
      expect(real.transactions, isEmpty);
      expect(real.dailyPaise, isNull);
      final demo = SpendingController(
        account: 'demo',
        demo: true,
        clock: () => september,
      );
      await demo.initialize();
      expect(demo.spendingPaise, 760000);
      expect(demo.budgetPaise, 1400000);
      expect(demo.spentFor('Food & cafés'), 420000);
      expect(demo.spentFor('Groceries'), 260000);
      expect(demo.spentFor('Travel'), 80000);
      expect(demo.budgets, {
        'Food & cafés': 500000,
        'Groceries': 500000,
        'Travel': 400000,
      });
      expect(
        demo.transactions.firstWhere(
          (t) => t['title'] == 'Beachside lunch',
        )['expenseId'],
        isNull,
      );
      real.dispose();
      demo.dispose();
    },
  );

  test(
    'monthly spend handles refunds, exclusions, transfers and group shares',
    () async {
      final c = controller();
      await c.importRows([
        payment(id: 'debit', amount: 120000),
        {
          ...payment(id: 'refund', amount: 20000, kind: 'refund'),
          'refundBudgetPaise': 20000,
        },
        payment(id: 'income', amount: 1000000, kind: 'credit'),
        payment(id: 'move', amount: 300000, kind: 'transfer'),
        {...payment(id: 'excluded', amount: 90000), 'excluded': true},
        {
          ...payment(id: 'group', amount: 126000),
          'groupId': 'goa',
          'expenseId': 'lunch',
          'sharePaise': 42000,
        },
        payment(
          id: 'last-month',
          amount: 100000,
          date: '2026-08-15T09:00:00.000Z',
        ),
      ]);
      expect(c.spendingPaise, 142000);
      expect(c.spentFor('Food & cafés'), 142000);
      expect(effectiveSpend({...payment(), 'excluded': true}), 0);
      expect(
        effectiveSpend({
          ...payment(kind: 'debit'),
          'expenseId': 'x',
          'sharePaise': 0,
        }),
        0,
      );
    },
  );

  test(
    'remaining budget preserves overspend but daily allowance bottoms at zero',
    () async {
      final c = controller();
      await c.setPayday(30);
      expect(c.dailyPaise, isNull);
      await c.setBudget('Food & cafés', 10000);
      expect(c.daysToPayday, 15);
      expect(c.dailyPaise, 666);
      await c.add(payment(amount: 12500));
      expect(c.remainingPaise, -2500);
      expect(c.dailyPaise, 0);
      await c.setBudget('Food & cafés', 0);
      expect(c.budgets, isEmpty);
      expect(c.dailyPaise, isNull);
    },
  );

  test(
    'unreviewed refunds do not inflate remaining or daily budgets',
    () async {
      final c = controller();
      await c.setBudget('Food & cafés', 200000);
      await c.setPayday(30);
      await c.add({
        ...payment(amount: 126000),
        'groupId': 'group',
        'expenseId': 'lunch',
        'sharePaise': 42000,
      });
      await c.add(payment(id: 'refund', amount: 126000, kind: 'refund'));
      expect(c.spendingPaise, 42000);
      expect(c.remainingPaise, 158000);
      expect(c.dailyPaise, 10533);
      expect(
        c.transactions.firstWhere(
          (row) => row['id'] == 'refund',
        )['refundBudgetPaise'],
        isNull,
      );
    },
  );

  test(
    'full bank refund of shared purchase reduces only confirmed personal portion',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add({
        ...payment(amount: 126000),
        'groupId': 'group',
        'expenseId': 'lunch',
        'sharePaise': 42000,
      });
      await c.add(payment(id: 'refund', amount: 126000, kind: 'refund'));
      await c.update('refund', {'refundBudgetPaise': 42000});
      expect(c.spendingPaise, 0);
      final restored = controller(store: store);
      await restored.initialize();
      expect(restored.spendingPaise, 0);
      expect(restored.exportCsv(), contains('Personal refund (INR)'));
      expect(
        restored
            .exportCsv()
            .split('\r\n')
            .firstWhere((line) => line.contains('"refund"')),
        endsWith('"420.00"'),
      );
    },
  );

  test(
    'partial group refund and zero-personal refund keep the correct share',
    () async {
      final c = controller();
      await c.add({
        ...payment(amount: 126000),
        'groupId': 'group',
        'expenseId': 'lunch',
        'sharePaise': 42000,
      });
      await c.add({
        ...payment(id: 'partial', amount: 60000, kind: 'refund'),
        'refundBudgetPaise': 20000,
      });
      expect(c.spendingPaise, 22000);
      await c.add({
        ...payment(id: 'others-only', amount: 10000, kind: 'refund'),
        'refundBudgetPaise': 0,
      });
      expect(c.spendingPaise, 22000);
      await c.update('partial', {'refundBudgetPaise': null});
      expect(c.spendingPaise, 42000);
    },
  );

  test(
    'refund allocation validates direction, integer bounds and exclusions',
    () async {
      final c = controller();
      await c.add(payment(id: 'refund', kind: 'refund'));
      for (final invalid in [-1, 12501, 1.5, '100']) {
        await expectLater(
          c.update('refund', {'refundBudgetPaise': invalid}),
          throwsFormatException,
        );
      }
      await expectLater(
        c.add({...payment(id: 'debit'), 'refundBudgetPaise': 100}),
        throwsFormatException,
      );
      await c.update('refund', {'refundBudgetPaise': 12500});
      expect(c.spendingPaise, -12500);
      await c.update('refund', {'excluded': true});
      expect(c.spendingPaise, 0);
    },
  );

  test(
    'payday clamps to month end and same-day payday advances without division by zero',
    () async {
      final february = controller(now: DateTime(2028, 2, 28));
      await february.setPayday(31);
      expect(february.daysToPayday, 1);
      final today = controller(now: DateTime(2028, 2, 29));
      await today.setPayday(31);
      expect(today.daysToPayday, 31);
      final december = controller(now: DateTime(2026, 12, 31));
      await december.setPayday(1);
      expect(december.daysToPayday, 1);
    },
  );

  test(
    'import dedupes references across sources but preserves account and direction',
    () async {
      final c = controller();
      final original = {
        ...payment(),
        'reference': ' UPI123 ',
        'accountLast4': '1234',
      };
      expect(await c.importRows([original]), 1);
      expect(
        await c.importRows([
          {
            ...original,
            'id': 'duplicate',
            'title': 'Different statement title',
            'source': 'Statement',
            'reference': 'upi123',
            'date': '2026-09-15T09:05:00Z',
          },
          {...original, 'id': 'other-account', 'accountLast4': '5678'},
          {...original, 'id': 'credit', 'kind': 'credit'},
          {...original, 'id': 'other-reference', 'reference': 'upi124'},
        ]),
        3,
      );
      expect(c.transactions, hasLength(4));
      expect(c.lastImport, september);
    },
  );

  test(
    'fallback dedupe preserves two same-value payments one minute apart',
    () async {
      final c = controller();
      expect(
        await c.importRows([
          payment(source: 'SMS'),
          payment(
            id: 'same-exact',
            title: 'COFFEE   SHOP',
            source: 'Statement',
          ),
          payment(id: 'later', date: '2026-09-15T09:01:00Z'),
        ]),
        2,
      );
      expect(await c.importRows([payment(id: 'repeat')]), 0);
      expect(c.transactions, hasLength(2));
    },
  );

  test(
    'same last four digits and reference at different banks stay separate',
    () async {
      final c = controller();
      final original = {
        ...payment(),
        'reference': 'UPI1234',
        'accountLast4': '1234',
        'bank': 'SBI',
      };
      expect(
        await c.importRows([
          original,
          {...original, 'id': 'another-bank', 'bank': 'HDFC'},
          {...original, 'id': 'same-bank-again', 'bank': ' sbi '},
        ]),
        2,
      );
    },
  );

  test(
    'changed linked expenses count original debit until reviewed and refreshed',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add({
        ...payment(),
        'groupId': 'group',
        'expenseId': 'expense',
        'sharePaise': 6250,
      });
      expect(c.spendingPaise, 6250);
      await c.update('one', {'linkNeedsReview': true});
      expect(c.spendingPaise, 12500);
      final restored = controller(store: store);
      await restored.initialize();
      expect(restored.spendingPaise, 12500);
      expect(restored.transactions.single['expenseId'], 'expense');
      await restored.update('one', {
        'linkNeedsReview': false,
        'sharePaise': 5000,
      });
      expect(restored.spendingPaise, 5000);
    },
  );

  test(
    'account deletion erases pending share despite ordinary clear lock',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add(payment());
      await c.update('one', {'pendingShare': pendingShare(12500)});
      await expectLater(c.clear(), throwsFormatException);
      await c.endSession(delete: true);
      expect(c.transactions, isEmpty);
      expect(store.value, isNull);
      expect(store.closed, isTrue);
    },
  );

  test(
    'explicit private-data deletion discards pending drafts and remains erased on reload',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add(payment());
      await c.update('one', {'pendingShare': pendingShare(12500)});
      await c.setBudget('Food & cafés', 100000);
      await c.setPayday(1);
      await c.clear(discardPending: true);
      expect(c.transactions, isEmpty);
      expect(c.budgets, isEmpty);
      expect(c.payday, isNull);
      final restored = controller(store: store);
      await restored.initialize();
      expect(restored.transactions, isEmpty);
      expect(jsonEncode(store.value), isNot(contains('expense-one')));
    },
  );

  test(
    'confirmed unsubmitted draft can be discarded and retried with a fresh payload',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add(payment());
      await c.update('one', {'pendingShare': pendingShare(12500)});
      await c.discardUnsubmittedShare('one');
      expect(c.transactions.single['pendingShare'], isNull);
      expect(c.spendingPaise, 12500);
      final restored = controller(store: store);
      await restored.initialize();
      expect(restored.transactions.single['pendingShare'], isNull);
      final next = pendingShare(12500);
      next['expenseId'] = 'second-attempt';
      next['payload']['id'] = 'second-attempt';
      next['payload']['description'] = 'Corrected title';
      await restored.update('one', {'pendingShare': next});
      expect(
        restored.transactions.single['pendingShare']['expenseId'],
        'second-attempt',
      );
    },
  );

  test(
    'import reassigns colliding IDs when transactions are genuinely distinct',
    () async {
      final c = controller();
      expect(
        await c.importRows([payment(), payment(title: 'Bus', amount: 5000)]),
        2,
      );
      expect(c.transactions.map((row) => row['id']).toSet(), hasLength(2));
    },
  );

  test(
    'merchant corrections survive restart and apply only to future matching purchases',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add({...payment(), 'merchantKey': ' Local Market '});
      await c.update('one', {'category': 'Groceries'});
      final restored = controller(store: store);
      await restored.initialize();
      await restored.importRows([
        {
          ...payment(id: 'future', amount: 13000),
          'merchantKey': 'local market',
        },
        payment(id: 'unrelated', title: 'Another café'),
      ]);
      expect(
        restored.transactions.firstWhere(
          (row) => row['id'] == 'future',
        )['category'],
        'Groceries',
      );
      expect(
        restored.transactions.firstWhere(
          (row) => row['id'] == 'unrelated',
        )['category'],
        'Food & cafés',
      );
    },
  );

  test('failed validation leaves batch, budget and payday unchanged', () async {
    final c = controller();
    await expectLater(
      c.importRows([payment(), payment(id: 'bad', amount: -1)]),
      throwsFormatException,
    );
    expect(c.transactions, isEmpty);
    expect(c.lastImport, isNull);
    await expectLater(
      c.setBudget('Wrong category', 100),
      throwsFormatException,
    );
    await expectLater(c.setBudget('Travel', -1), throwsFormatException);
    await expectLater(c.setPayday(0), throwsFormatException);
    await expectLater(c.setPayday(32), throwsFormatException);
    expect(c.budgets, isEmpty);
    expect(c.payday, isNull);
    await expectLater(
      c.add({...payment(), 'accountLast4': '123456789'}),
      throwsFormatException,
    );
    await expectLater(
      c.add({...payment(), 'expenseId': 'x'}),
      throwsFormatException,
    );
  });

  test(
    'persistence failure rolls back state and later saves can recover',
    () async {
      final store = MemorySpendingStore()..fail = true;
      final c = controller(store: store);
      await expectLater(c.add(payment()), throwsStateError);
      expect(c.transactions, isEmpty);
      expect(c.error, isNotNull);
      store.fail = false;
      await c.add(payment());
      expect(c.transactions, hasLength(1));
      expect(c.error, isNull);
    },
  );

  test(
    'parallel mutations serialize without losing transactions or caps',
    () async {
      final c = controller();
      await Future.wait([
        c.add(payment()),
        c.add(payment(id: 'two')),
        c.setBudget('Travel', 50000),
        c.setBudget('Food & cafés', 60000),
      ]);
      expect(c.transactions, hasLength(2));
      expect(c.budgetPaise, 110000);
    },
  );

  test(
    'input allowlist drops raw SMS and CSV escapes formulas and quotes',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add({
        ...payment(title: '=HYPERLINK("https://example.test")'),
        'rawSms': 'OTP-SECRET-CANARY',
        'body': 'PERSONAL-MESSAGE-CANARY',
      });
      expect(jsonEncode(store.value), isNot(contains('CANARY')));
      final csv = c.exportCsv();
      expect(csv, contains('"\'=HYPERLINK(""https://example.test"")"'));
      expect(csv, contains('"125.00"'));
      expect(csv, isNot(contains('rawSms')));
    },
  );

  test('public collections cannot mutate ledger or pending payloads', () async {
    final c = controller();
    await c.add(payment());
    await c.update('one', {'pendingShare': pendingShare(12500)});
    expect(() => c.transactions.clear(), throwsUnsupportedError);
    expect(
      () => c.transactions.first['title'] = 'changed',
      throwsUnsupportedError,
    );
    expect(
      () => c.transactions.first['pendingShare']['payload']['amountPaise'] = 1,
      throwsUnsupportedError,
    );
    expect(() => c.budgets['Other'] = 1, throwsUnsupportedError);
  });

  test(
    'pending sharing survives reload and locks edits and deletes until acknowledgement',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add(payment());
      await c.update('one', {'pendingShare': pendingShare(12500)});
      final restored = controller(store: store);
      await restored.initialize();
      expect(
        restored.transactions.single['pendingShare']['expenseId'],
        'expense-one',
      );
      await expectLater(restored.remove('one'), throwsFormatException);
      await expectLater(restored.clear(), throwsFormatException);
      await expectLater(
        restored.update('one', {'amountPaise': 10000}),
        throwsFormatException,
      );
      await expectLater(
        restored.update('one', {'pendingShare': null}),
        throwsFormatException,
      );
      await restored.update('one', {
        'groupId': 'group',
        'expenseId': 'expense-one',
        'sharePaise': 6250,
        'pendingShare': null,
      });
      expect(restored.transactions.single['pendingShare'], isNull);
      expect(restored.spendingPaise, 6250);
      await expectLater(
        restored.update('one', {'amountPaise': 20000}),
        throwsFormatException,
      );
      await restored.update('one', {'category': 'Other'});
      expect(restored.spentFor('Other'), 6250);
      await restored.remove('one');
      expect(restored.transactions, isEmpty);
    },
  );

  test(
    'pending share must match payment and only keeps reviewed payload fields',
    () async {
      final c = controller();
      await c.add(payment());
      await expectLater(
        c.update('one', {'pendingShare': pendingShare(1)}),
        throwsFormatException,
      );
      final draft = pendingShare(12500);
      draft['payload']['rawSms'] = 'SECRET';
      await c.update('one', {'pendingShare': draft});
      expect(jsonEncode(c.transactions), isNot(contains('SECRET')));
    },
  );

  test(
    'clearing removes rules and settings and remains empty after restart',
    () async {
      final store = MemorySpendingStore();
      final c = controller(store: store);
      await c.add(payment());
      await c.update('one', {'category': 'Groceries'});
      await c.setBudget('Groceries', 100000);
      await c.setPayday(1);
      await c.clear();
      final restored = controller(store: store);
      await restored.initialize();
      expect(restored.transactions, isEmpty);
      expect(restored.budgets, isEmpty);
      expect(restored.payday, isNull);
      await restored.add(payment());
      expect(restored.transactions.single['category'], 'Food & cafés');
    },
  );

  test(
    'account session closure prevents late loading from revealing balances',
    () async {
      final store = MemorySpendingStore()..pendingLoad = Completer<Json?>();
      final c = controller(store: store);
      final initializing = c.initialize();
      await c.endSession();
      store.pendingLoad!.complete({
        'version': 1,
        'transactions': [payment()],
        'budgets': {},
      });
      await initializing;
      expect(c.transactions, isEmpty);
      expect(c.loaded, isFalse);
      expect(() => c.add(payment()), throwsStateError);
      expect(() => c.exportCsv(), throwsStateError);
    },
  );

  test('account closure during write cannot restore private state', () async {
    final store = MemorySpendingStore()..pendingSave = Completer<void>();
    final c = controller(store: store);
    await c.initialize();
    final saving = c.add(payment());
    final rejected = expectLater(saving, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final closing = c.endSession();
    store.pendingSave!.complete();
    await rejected;
    await closing;
    expect(c.transactions, isEmpty);
    expect(c.error, isNull);
  });

  test('a store belonging to another account is rejected', () {
    expect(
      () => SpendingController(
        account: 'bob',
        store: MemorySpendingStore('alice'),
      ),
      throwsArgumentError,
    );
  });

  test(
    'encrypted ledger survives restart, freezes writes and isolates account AAD',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hisaab-spending-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = SecretKey(List<int>.generate(32, (index) => index));
      SpendingStore store(String account) => SpendingStore(
        account,
        directoryOverride: directory,
        keyOverride: key,
      );
      final alice = store('alice');
      final input = <String, dynamic>{'merchant': 'PRIVATE-SPENDING-CANARY'};
      final writing = alice.save(input);
      input['merchant'] = 'changed after queue';
      await writing;
      await alice.close();
      expect(
        (await store('alice').load())!['merchant'],
        'PRIVATE-SPENDING-CANARY',
      );
      final aliceFile =
          (await directory
                  .list(recursive: true)
                  .where((file) => file is File)
                  .cast<File>()
                  .toList())
              .single;
      final ciphertext = await aliceFile.readAsBytes();
      expect(latin1.decode(ciphertext), isNot(contains('PRIVATE-SPENDING')));
      final bob = store('bob');
      expect(await bob.load(), isNull);
      await bob.save({'merchant': 'bob'});
      final bobFile =
          (await directory
                  .list(recursive: true)
                  .where((file) => file is File && file.path != aliceFile.path)
                  .cast<File>()
                  .toList())
              .single;
      await bobFile.writeAsBytes(ciphertext);
      await expectLater(
        bob.load(),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      final corrupt = ciphertext.toList()..[ciphertext.length - 1] ^= 1;
      await aliceFile.writeAsBytes(corrupt);
      await expectLater(
        store('alice').load(),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    },
  );

  test(
    'serialized encrypted writes retain last snapshot and deletion closes store',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hisaab-spending-writes-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = SecretKey(List.filled(32, 4));
      final store = SpendingStore(
        'alice',
        directoryOverride: directory,
        keyOverride: key,
      );
      await Future.wait([
        store.save({'n': 1}),
        store.save({'n': 2}),
        store.save({'n': 3}),
      ]);
      expect((await store.load())!['n'], 3);
      await store.close(delete: true);
      expect(() => store.save({'n': 4}), throwsStateError);
      final reopened = SpendingStore(
        'alice',
        directoryOverride: directory,
        keyOverride: key,
      );
      expect(await reopened.load(), isNull);
      expect(
        await directory
            .list(recursive: true)
            .where((file) => file is File)
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'closing before a queued encrypted write prevents a stale ledger',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hisaab-spending-close-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = SpendingStore(
        'alice',
        directoryOverride: directory,
        keyOverride: SecretKey(List.filled(32, 5)),
      );
      final write = store.save({'private': 'value'});
      final rejected = expectLater(write, throwsStateError);
      await store.close(delete: true);
      await rejected;
      expect(
        await directory
            .list(recursive: true)
            .where((file) => file is File)
            .toList(),
        isEmpty,
      );
    },
  );
}
