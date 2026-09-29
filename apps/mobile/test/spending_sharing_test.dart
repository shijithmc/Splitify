import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/repository.dart';
import 'package:hisaab/core/spending.dart';
import 'package:hisaab/core/spending_import.dart';
import 'package:hisaab/core/spending_sharing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SharingRepository implements Repository {
  final Repository delegate;
  final calls = <Json>[];
  bool loseNextPostResponse = false, conflictAfterNextPost = false;
  int? rejectNextPostStatus;
  bool? demoOverride;
  Completer<void>? getStarted, releaseGet;
  Future<void> Function()? afterPost;
  SharingRepository(this.delegate);
  @override
  bool get isDemo => demoOverride ?? delegate.isDemo;
  @override
  bool get offline => delegate.offline;
  @override
  Json? get session => delegate.session;
  @override
  Future<void> close() => delegate.close();
  List<Json> get expensePosts => calls
      .where(
        (call) =>
            call['method'] == 'POST' &&
            (call['path'] as String).endsWith('/expenses'),
      )
      .toList();
  @override
  Future<Json> request(String method, String path, [Json? data]) async {
    calls.add({
      'method': method,
      'path': path,
      'data': data == null ? null : jsonDecode(jsonEncode(data)),
    });
    if (method == 'GET' &&
        RegExp(r'^/groups/[^/]+/expenses/[^/]+$').hasMatch(path) &&
        releaseGet != null) {
      if (getStarted?.isCompleted == false) getStarted!.complete();
      await releaseGet!.future;
    }
    if (method == 'POST' &&
        path.endsWith('/expenses') &&
        rejectNextPostStatus != null) {
      final status = rejectNextPostStatus!;
      rejectNextPostStatus = null;
      throw ApiFailure('Request explicitly rejected', status: status);
    }
    final result = await delegate.request(method, path, data);
    if (method == 'POST' && path.endsWith('/expenses')) {
      await afterPost?.call();
      if (loseNextPostResponse) {
        loseNextPostResponse = false;
        throw ApiFailure(
          'Response lost after saving',
          code: 'network',
          status: 0,
        );
      }
      if (conflictAfterNextPost) {
        conflictAfterNextPost = false;
        throw ApiFailure(
          'Expense already exists',
          code: 'expense_exists',
          status: 409,
        );
      }
    }
    return result;
  }
}

class DelayedSpendingImport extends SpendingImportService {
  final started = Completer<void>();
  final result = Completer<List<Json>>();
  int acknowledgements = 0;
  DelayedSpendingImport() : super(android: true);
  @override
  Future<void> configureOwner(String? ownerId) async {}
  @override
  Future<bool> smsEnabled() async => true;
  @override
  Future<List<Json>> importSms({bool requestPermission = false}) async {
    started.complete();
    return result.future;
  }

  @override
  Future<void> disableSms() async {}
  @override
  Future<void> clearImportedData() async {}
  @override
  Future<void> acknowledgeSms() async {
    acknowledgements++;
  }
}

class MemoryImportController extends AppController {
  final personal = SpendingController(account: 'demo-you', demo: true);
  MemoryImportController(SpendingImportService importer)
    : super(spendingImports: importer);
  @override
  SpendingController get spending => personal;
  @override
  void dispose() {
    personal.dispose();
    super.dispose();
  }
}

class DelayedOwnerImport extends SpendingImportService {
  bool holdClose = false;
  final closeStarted = Completer<void>();
  final releaseClose = Completer<void>();
  DelayedOwnerImport() : super(android: false);
  @override
  Future<void> configureOwner(String? ownerId) async {
    if (ownerId == null && holdClose) {
      closeStarted.complete();
      await releaseClose.future;
    }
  }
}

class SharingFixture {
  final AppController controller;
  final SharingRepository repository;
  final Group group;
  SharingFixture(this.controller, this.repository, this.group);
  String get me => group.participant(controller.userId)!;
  Set<String> get participants => group.members.map((m) => m.id).toSet();
  SpendingShareService get service => SpendingShareService(controller);
  Future<Json> share([String id = 'private-one']) => service.share(
    transactionId: id,
    group: group,
    participants: participants,
    description: 'Lunch with friends',
  );
  Future<Json> existingExpense([String id = 'existing-expense']) =>
      repository.delegate.request(
        'POST',
        '/groups/${group.id}/expenses',
        spendingExpensePayload(
          transaction: purchase(),
          expenseId: id,
          payerId: me,
          participants: participants,
          description: 'Already shared lunch',
        ),
      );
}

Json purchase([String id = 'private-one']) => {
  'id': id,
  'title': 'Private bank label',
  'amountPaise': 126000,
  'date': DateTime.now().toUtc().toIso8601String(),
  'category': 'Food & cafés',
  'kind': 'debit',
  'source': 'SMS',
  'bank': 'PRIVATE-BANK-CANARY',
  'reference': 'PRIVATE-REFERENCE-CANARY',
  'accountLast4': '4321',
  'merchantKey': 'PRIVATE-MERCHANT-CANARY',
  'rawSms': 'PRIVATE-SMS-CANARY',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<SharingFixture> fixture({SpendingImportService? importer}) async {
    final c = AppController(spendingImports: importer);
    await c.startDemo();
    final repository = SharingRepository(c.repository!);
    c.repository = repository;
    await c.spending.clear();
    await c.spending.add(purchase());
    final group = c.groups.firstWhere((g) => g.type == 'Trip');
    addTearDown(c.dispose);
    return SharingFixture(c, repository, group);
  }

  test('shared payload is a strict reviewed-field allowlist', () {
    final payload = spendingExpensePayload(
      transaction: purchase(),
      expenseId: 'expense',
      payerId: 'you',
      participants: {'you', 'friend'},
      description: '  Reviewed lunch  ',
    );
    expect(payload.keys.toSet(), {
      'id',
      'description',
      'amountPaise',
      'date',
      'payerId',
      'mode',
      'participants',
    });
    expect(payload['description'], 'Reviewed lunch');
    expect(jsonEncode(payload), isNot(contains('PRIVATE-')));
    expect(jsonEncode(payload), isNot(contains('4321')));
    expect(payload['participants'], [
      {'participantId': 'friend', 'value': 1},
      {'participantId': 'you', 'value': 1},
    ]);
    expect(
      () => spendingExpensePayload(
        transaction: purchase(),
        expenseId: 'expense',
        payerId: 'you',
        participants: {},
        description: 'Lunch',
      ),
      throwsFormatException,
    );
    expect(
      () => spendingExpensePayload(
        transaction: purchase(),
        expenseId: 'expense',
        payerId: 'you',
        participants: {'you'},
        description: ' ',
      ),
      throwsFormatException,
    );
  });

  test(
    'sharing creates one expense and budgets only your confirmed share',
    () async {
      final f = await fixture();
      final saved = await f.share();
      expect(saved['amountPaise'], 126000);
      expect(object(saved['shares'])[f.me], 42000);
      expect(f.controller.spending.spendingPaise, 42000);
      final row = f.controller.spending.transactions.single;
      expect(row['expenseId'], saved['id']);
      expect(row['groupId'], f.group.id);
      expect(row['pendingShare'], isNull);
      expect(row['reference'], 'PRIVATE-REFERENCE-CANARY');
      expect(f.repository.expensePosts, hasLength(1));
      expect(
        jsonEncode(f.repository.expensePosts.single['data']),
        isNot(contains('PRIVATE-')),
      );
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      expect(f.repository.expensePosts, hasLength(1));
    },
  );

  test(
    'a lost POST response recovers persisted expense ID without creating twice',
    () async {
      final f = await fixture();
      f.repository.loseNextPostResponse = true;
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      final pending = object(
        f.controller.spending.transactions.single['pendingShare'],
      );
      final stableId = pending['expenseId'];
      expect(stableId, isNotNull);
      expect(f.controller.spending.spendingPaise, 126000);
      final recovered = await f.share();
      expect(recovered['id'], stableId);
      expect(f.repository.expensePosts, hasLength(1));
      expect(f.controller.spending.spendingPaise, 42000);
      expect(f.controller.spending.transactions.single['pendingShare'], isNull);
    },
  );

  test('409 recovery reuses the persisted expense ID', () async {
    final f = await fixture();
    f.repository.conflictAfterNextPost = true;
    final saved = await f.share();
    expect(f.repository.expensePosts, hasLength(1));
    expect(f.controller.spending.transactions.single['expenseId'], saved['id']);
    expect(f.controller.spending.spendingPaise, 42000);
  });

  for (final status in [400, 422]) {
    test(
      'a new POST rejected with $status releases its draft for correction',
      () async {
        final f = await fixture();
        f.repository.rejectNextPostStatus = status;
        await expectLater(f.share(), throwsA(isA<ApiFailure>()));
        expect(
          f.controller.spending.transactions.single['pendingShare'],
          isNull,
        );
        final firstId = f.repository.expensePosts.single['data']['id'];
        final saved = await f.share();
        expect(saved['id'], isNot(firstId));
        expect(f.controller.spending.spendingPaise, 42000);
      },
    );
  }

  test(
    '403 keeps uncertain draft rather than silently changing its ID',
    () async {
      final f = await fixture();
      f.repository.rejectNextPostStatus = 403;
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      final pendingId = f
          .controller
          .spending
          .transactions
          .single['pendingShare']['expenseId'];
      final saved = await f.share();
      expect(saved['id'], pendingId);
    },
  );

  test(
    'a later validation rejection does not discard an older uncertain draft',
    () async {
      final f = await fixture();
      f.repository.rejectNextPostStatus = 403;
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      final pendingId = f
          .controller
          .spending
          .transactions
          .single['pendingShare']['expenseId'];
      f.repository.rejectNextPostStatus = 422;
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      expect(
        f.controller.spending.transactions.single['pendingShare']['expenseId'],
        pendingId,
      );
    },
  );

  test(
    'existing expense linking changes only private budget and rejects another link',
    () async {
      final f = await fixture();
      final existing = await f.existingExpense();
      await f.controller.spending.add(purchase('private-two'));
      await f.service.link(
        transactionId: 'private-one',
        group: f.group,
        expenseId: existing['id'],
      );
      expect(f.controller.spending.spendingPaise, 168000);
      expect(f.repository.expensePosts, isEmpty);
      await expectLater(
        f.service.link(
          transactionId: 'private-two',
          group: f.group,
          expenseId: existing['id'],
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(
        f.controller.spending.transactions.where(
          (row) => row['expenseId'] != null,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'transfers, excluded payments and omitted payer never reach group POST',
    () async {
      final f = await fixture();
      await f.controller.spending.update('private-one', {'kind': 'transfer'});
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      await f.controller.spending.update('private-one', {
        'kind': 'debit',
        'excluded': true,
      });
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      await f.controller.spending.update('private-one', {'excluded': false});
      await expectLater(
        f.service.share(
          transactionId: 'private-one',
          group: f.group,
          participants: f.participants..remove(f.me),
          description: 'Lunch',
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(f.repository.expensePosts, isEmpty);
      expect(f.controller.spending.transactions.single['pendingShare'], isNull);
    },
  );

  test(
    'account switch during lookup prevents POST and private acknowledgement',
    () async {
      final f = await fixture();
      final oldStore = f.controller.spending;
      f.repository.getStarted = Completer<void>();
      f.repository.releaseGet = Completer<void>();
      final pending = f.share();
      final rejected = expectLater(pending, throwsA(isA<ApiFailure>()));
      await f.repository.getStarted!.future;
      final replacement = SharingRepository(f.repository.delegate);
      f.controller.repository = replacement;
      f.controller.user = {'id': 'another-account'};
      f.repository.releaseGet!.complete();
      await rejected;
      expect(f.repository.expensePosts, isEmpty);
      expect(replacement.calls, isEmpty);
      expect(oldStore.transactions.single['expenseId'], isNull);
      expect(oldStore.transactions.single['pendingShare'], isNotNull);
    },
  );

  test(
    'account switch during 409 response never sends recovery under new account',
    () async {
      final f = await fixture();
      final replacement = SharingRepository(f.repository.delegate);
      f.repository.conflictAfterNextPost = true;
      f.repository.afterPost = () async {
        f.controller.repository = replacement;
        f.controller.user = {'id': 'another-account'};
      };
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      expect(replacement.calls, isEmpty);
      expect(f.controller.spending.transactions, isEmpty);
    },
  );

  test(
    'separate service instances cannot share the same payment concurrently',
    () async {
      final f = await fixture();
      f.repository.getStarted = Completer<void>();
      f.repository.releaseGet = Completer<void>();
      final first = f.share();
      await f.repository.getStarted!.future;
      final second = expectLater(f.share(), throwsA(isA<ApiFailure>()));
      f.repository.releaseGet!.complete();
      await first;
      await second;
      expect(f.repository.expensePosts, hasLength(1));
      expect(f.controller.spending.spendingPaise, 42000);
    },
  );

  test(
    'simultaneous existing links cannot attach two payments to one expense',
    () async {
      final f = await fixture();
      final existing = await f.existingExpense();
      await f.controller.spending.add(purchase('private-two'));
      f.repository.getStarted = Completer<void>();
      f.repository.releaseGet = Completer<void>();
      final first = f.service.link(
        transactionId: 'private-one',
        group: f.group,
        expenseId: existing['id'],
      );
      await f.repository.getStarted!.future;
      final second = expectLater(
        f.service.link(
          transactionId: 'private-two',
          group: f.group,
          expenseId: existing['id'],
        ),
        throwsA(isA<ApiFailure>()),
      );
      f.repository.releaseGet!.complete();
      await first;
      await second;
      expect(
        f.controller.spending.transactions.where(
          (row) => row['expenseId'] != null,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'pending success recovers even if a participant has since left the group',
    () async {
      final f = await fixture();
      f.repository.loseNextPostResponse = true;
      await expectLater(f.share(), throwsA(isA<ApiFailure>()));
      final leftId = f.group.members
          .firstWhere((member) => member.id != f.me)
          .id;
      final detail = await f.repository.delegate.request(
        'GET',
        '/groups/${f.group.id}',
      );
      final members = rows(detail['members']);
      members.firstWhere((row) => row['id'] == leftId)['hasLeft'] = true;
      final changedGroup = Group.from({...detail, 'members': members});
      final saved = await f.service.share(
        transactionId: 'private-one',
        group: changedGroup,
        participants: f.participants,
        description: 'Lunch with friends',
      );
      expect(
        saved['id'],
        f.controller.spending.transactions.single['expenseId'],
      );
      expect(f.repository.expensePosts, hasLength(1));
    },
  );

  test(
    'private-data deletion invalidates an SMS import already in flight',
    () async {
      final importer = DelayedSpendingImport();
      final c = MemoryImportController(importer);
      await c.startDemo();
      await c.spending.clear();
      c.repository = SharingRepository(c.repository!)..demoOverride = false;
      addTearDown(c.dispose);
      final importing = c.syncSpendingSms();
      await importer.started.future;
      await c.clearPrivateSpending();
      importer.result.complete([purchase()]);
      await importing;
      expect(c.spending.transactions, isEmpty);
      expect(importer.acknowledgements, 0);
    },
  );

  test(
    'shutdown cannot recreate the old ledger while native owner clearing is delayed',
    () async {
      final importer = DelayedOwnerImport();
      final c = AppController(spendingImports: importer);
      await c.startDemo();
      await c.spending.clear();
      await c.spending.add(purchase());
      final oldStore = c.spending;
      final repository = c.repository!;
      importer.holdClose = true;
      final closing = c.logout();
      await importer.closeStarted.future;
      expect(c.spendingAvailable, isFalse);
      expect(identical(c.spending, oldStore), isTrue);
      expect(c.spending.transactions, isEmpty);
      expect(() => c.spending.initialize(), throwsStateError);
      importer.releaseClose.complete();
      await closing;
      c.repository = SharingRepository(repository);
      c.user = {'id': 'new-account'};
      expect(c.spendingAvailable, isTrue);
      expect(identical(c.spending, oldStore), isFalse);
      expect(c.spending.account, 'new-account');
      expect(c.spending.transactions, isEmpty);
      expect(oldStore.transactions, isEmpty);
      c.dispose();
    },
  );

  test(
    'logout during a pending lookup cannot create an expense after its 404 reply',
    () async {
      final importer = DelayedOwnerImport();
      final f = await fixture(importer: importer);
      f.repository.getStarted = Completer<void>();
      f.repository.releaseGet = Completer<void>();
      final sharing = f.share().then<Object?>(
        (_) => null,
        onError: (Object error, StackTrace _) => error,
      );
      await f.repository.getStarted!.future;
      importer.holdClose = true;
      final closing = f.controller.logout();
      await importer.closeStarted.future;
      f.repository.releaseGet!.complete();
      final result = await sharing;
      importer.releaseClose.complete();
      await closing;
      expect(result, isA<ApiFailure>());
      expect(f.repository.expensePosts, isEmpty);
    },
  );
}
