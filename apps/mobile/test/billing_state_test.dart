import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/repository.dart';

class PendingStoreRepository implements Repository {
  bool fail = true;
  String status = 'free';
  String account = 'account-a';
  @override
  bool get isDemo => false;
  @override
  bool get offline => false;
  @override
  Json get session => {
    'user': {'id': account},
    'accessToken': 'a',
  };
  @override
  Future<Json> request(String method, String path, [Json? data]) async {
    if (fail) throw ApiFailure('Verification pending', status: 503);
    return {'adFree': status == 'active', 'status': status};
  }

  @override
  Future<void> close() async {}
}

class DeferredRepository extends PendingStoreRepository {
  final response = Completer<Json>();
  @override
  Future<Json> request(String method, String path, [Json? data]) =>
      response.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'SDK suppression is account-scoped, bounded and never extended by failed verification',
    () async {
      final repo = PendingStoreRepository();
      final c = AppController()
        ..repository = repo
        ..user = {'id': 'account-a'};
      await expectLater(
        c.refreshBilling(expectedAccount: 'account-a', provisional: true),
        throwsA(isA<ApiFailure>()),
      );
      final deadline = c.provisionalUntil!;
      expect(c.adFree, isTrue);
      expect(
        deadline.difference(DateTime.now()).inHours,
        lessThanOrEqualTo(24),
      );
      expect(
        await const FlutterSecureStorage().read(
          key: 'hisaab.provisional.account-a',
        ),
        isNotNull,
      );
      await expectLater(
        c.refreshBilling(expectedAccount: 'account-a', provisional: true),
        throwsA(isA<ApiFailure>()),
      );
      expect(c.provisionalUntil, deadline);
      c.provisionalUntil = DateTime.now().subtract(const Duration(seconds: 1));
      expect(c.adFree, isFalse);
      repo.fail = false;
      repo.status = 'expired';
      await c.refreshBilling(expectedAccount: 'account-a');
      expect(c.provisionalUntil, isNull);
      expect(
        await const FlutterSecureStorage().read(
          key: 'hisaab.provisional.account-a',
        ),
        isNull,
      );
      c.dispose();
    },
  );
  test(
    'delayed propagation survives restart only for the same account',
    () async {
      final repo = PendingStoreRepository()..fail = false;
      final c = AppController()
        ..repository = repo
        ..user = {'id': 'account-a'};
      await c.refreshBilling(expectedAccount: 'account-a', provisional: true);
      final deadline = c.provisionalUntil;
      expect(c.adFree, isTrue);
      await c.refreshBilling(expectedAccount: 'account-a');
      expect(c.provisionalUntil, deadline);
      final other = AppController()
        ..repository = (PendingStoreRepository()..account = 'account-b')
        ..user = {'id': 'account-b'};
      await other.restoreBillingState();
      expect(other.provisionalUntil, isNull);
      expect(other.adFree, isFalse);
      final restarted = AppController()
        ..repository = repo
        ..user = {'id': 'account-a'};
      await restarted.restoreBillingState();
      expect(restarted.provisionalUntil!.isAtSameMomentAs(deadline!), isTrue);
      expect(restarted.adFree, isTrue);
      repo.status = 'active';
      await restarted.refreshBilling(expectedAccount: 'account-a');
      expect(restarted.provisionalUntil, isNull);
      expect(restarted.adFree, isTrue);
      c.dispose();
      other.dispose();
      restarted.dispose();
    },
  );
  test('old account SDK completion cannot provision the new account', () async {
    final c = AppController()
      ..repository = (PendingStoreRepository()..account = 'account-b')
      ..user = {'id': 'account-b'};
    await expectLater(
      c.refreshBilling(expectedAccount: 'account-a', provisional: true),
      throwsA(isA<ApiFailure>()),
    );
    expect(c.provisionalUntil, isNull);
    expect(c.adFree, isFalse);
    expect(
      await const FlutterSecureStorage().read(
        key: 'hisaab.provisional.account-b',
      ),
      isNull,
    );
    c.dispose();
  });
  test(
    'old billing response cannot replace the new account entitlement',
    () async {
      final old = DeferredRepository();
      final c = AppController()
        ..repository = old
        ..user = {'id': 'account-a'};
      final pending = c.refreshBilling(expectedAccount: 'account-a');
      c.repository = PendingStoreRepository()..account = 'account-b';
      c.user = {'id': 'account-b'};
      old.response.complete({'adFree': true, 'status': 'active'});
      await pending;
      expect(c.adFree, isFalse);
      c.dispose();
    },
  );
  test('old request 401 cannot sign out a new account', () async {
    final old = DeferredRepository();
    final next = PendingStoreRepository()..account = 'account-b';
    final c = AppController()
      ..repository = old
      ..user = {'id': 'account-a'};
    final pending = c.request('GET', '/groups');
    c.repository = next;
    c.user = {'id': 'account-b'};
    old.response.completeError(ApiFailure('Expired', status: 401));
    await expectLater(pending, throwsA(isA<ApiFailure>()));
    expect(c.repository, same(next));
    expect(c.userId, 'account-b');
    expect(c.signedIn, isTrue);
    c.dispose();
  });
}
