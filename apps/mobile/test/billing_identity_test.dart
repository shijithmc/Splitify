import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/native_services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

class FakeBillingSdk implements BillingSdk {
  bool configured = false, failLogin = false, failLogout = false;
  String current = 'anonymous';
  int operations = 0;
  Completer<bool>? pendingRestore;
  @override
  Future<bool> isConfigured() async => configured;
  @override
  Future<void> configure(String key, String userId) async {
    configured = true;
    current = userId;
  }

  @override
  Future<void> logIn(String userId) async {
    if (failLogin) throw StateError('login failed');
    current = userId;
  }

  @override
  Future<void> logOut() async {
    if (failLogout) throw StateError('logout failed');
    current = 'anonymous';
  }

  @override
  Future<String> currentUserId() async => current;
  @override
  Future<List<Package>> packages() async {
    operations++;
    return [];
  }

  @override
  Future<bool> purchase(Package package) async {
    operations++;
    return true;
  }

  @override
  Future<bool> restore() {
    operations++;
    return pendingRestore?.future ?? Future.value(true);
  }

  @override
  Future<bool> active() async {
    operations++;
    return true;
  }
}

class UnusedPackage implements Package {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'failed logout and failed next identity cannot use previous or anonymous account',
    () async {
      final sdk = FakeBillingSdk();
      final billing = BillingService(
        sdk: sdk,
        apiKey: 'public-test-key',
        supported: true,
      );
      await billing.identify('A');
      expect(billing.readyFor('A'), isTrue);
      sdk.failLogout = true;
      final signout = billing.signOut();
      expect(billing.readyFor('A'), isFalse);
      await expectLater(signout, throwsStateError);
      sdk.failLogin = true;
      await expectLater(billing.identify('B'), throwsStateError);
      expect(billing.readyFor('B'), isFalse);
      expect(billing.readyFor('A'), isFalse);
      await expectLater(billing.packages('B'), throwsA(isA<ApiFailure>()));
      await expectLater(
        billing.purchase('B', UnusedPackage()),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(billing.restore('B'), throwsA(isA<ApiFailure>()));
      await expectLater(
        billing.storeEntitlementActive('B'),
        throwsA(isA<ApiFailure>()),
      );
      expect(sdk.operations, 0);
    },
  );
  test(
    'late purchase restore result is rejected after account transition begins',
    () async {
      final sdk = FakeBillingSdk();
      final billing = BillingService(
        sdk: sdk,
        apiKey: 'public-test-key',
        supported: true,
      );
      await billing.identify('A');
      sdk.pendingRestore = Completer<bool>();
      final restored = billing.restore('A');
      while (sdk.operations == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final rejected = expectLater(restored, throwsA(isA<ApiFailure>()));
      final switched = billing.identify('B');
      expect(billing.readyFor('A'), isFalse);
      sdk.pendingRestore!.complete(true);
      await rejected;
      await switched;
      expect(billing.readyFor('B'), isTrue);
      await expectLater(billing.restore('A'), throwsA(isA<ApiFailure>()));
    },
  );
  test(
    'unexpected native identity is rejected before any store operation',
    () async {
      final sdk = FakeBillingSdk();
      final billing = BillingService(
        sdk: sdk,
        apiKey: 'public-test-key',
        supported: true,
      );
      await billing.identify('A');
      sdk.current = 'anonymous';
      await expectLater(billing.restore('A'), throwsA(isA<ApiFailure>()));
      expect(billing.readyFor('A'), isFalse);
      expect(sdk.operations, 0);
    },
  );
}
