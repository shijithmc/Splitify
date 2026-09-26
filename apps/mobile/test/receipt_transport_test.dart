import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Json session(String id, [String token = 'token']) => {
  'user': {'id': id},
  'accessToken': token,
  'refreshToken': 'refresh',
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'receipt retry reuses persisted command key and never serves offline cached data',
    () async {
      var offline = false;
      final keys = <String?>[];
      final repo = ApiRepository(
        'https://api.invalid',
        client: MockClient((request) async {
          keys.add(request.headers['Idempotency-Key']);
          if (offline) throw const SocketException('offline');
          return http.Response('{"id":"receipt-private"}', 200);
        }),
      );
      await repo.saveSession(session('a'));
      await repo.receiptRequest('POST', '/groups/g/receipts', {
        'id': 'r',
      }, 'stable-command');
      await repo.receiptRequest('GET', '/receipts/r', null, 'get');
      offline = true;
      await expectLater(
        repo.receiptRequest('GET', '/receipts/r', null, 'get'),
        throwsA(isA<ApiFailure>()),
      );
      offline = false;
      await repo.receiptRequest('POST', '/groups/g/receipts', {
        'id': 'r',
      }, 'stable-command');
      expect(keys.first, keys.last);
      expect(
        (await const FlutterSecureStorage().read(key: 'hisaab.cache.a')) ?? '',
        isNot(contains('receipt-private')),
      );
      await repo.close();
    },
  );
  test(
    'remote upload never receives bearer; local upload is authenticated',
    () async {
      final requests = <http.Request>[];
      final repo = ApiRepository(
        'https://api.invalid',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('', 200);
        }),
      );
      await repo.saveSession(session('a', 'private-access-token'));
      final bytes = Uint8List.fromList([1, 2, 3]);
      await repo.uploadReceipt(
        {
          'url': 'https://bucket.s3.example/r',
          'headers': {'x-checksum': 'test'},
        },
        bytes,
        (_) {},
      );
      await repo.uploadReceipt(
        {'url': '/v1/receipts/r/uploads/image'},
        bytes,
        (_) {},
      );
      expect(requests[0].headers['Authorization'], isNull);
      expect(
        requests[1].headers['Authorization'],
        'Bearer private-access-token',
      );
      expect(requests[0].bodyBytes, bytes);
      await expectLater(
        repo.uploadReceipt({'url': 'http://evil.invalid/r'}, bytes, (_) {}),
        throwsA(isA<ApiFailure>()),
      );
      await repo.close();
    },
  );
  test(
    'media rechecks bearer and rejects responses completed after account change',
    () async {
      final pending = Completer<http.Response>();
      final repo = ApiRepository(
        'https://api.invalid',
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer a-token');
          expect(request.headers['Cache-Control'], 'no-store');
          return pending.future;
        }),
      );
      await repo.saveSession(session('a', 'a-token'));
      final fetch = repo.receiptBytes('/receipts/r/media/i?ticket=t');
      await Future<void>.delayed(Duration.zero);
      await repo.saveSession(session('b', 'b-token'));
      pending.complete(http.Response.bytes([1, 2, 3], 200));
      await expectLater(
        fetch,
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 401)),
      );
      await repo.close();
    },
  );
  test('bounded media chunks reject an oversized response', () async {
    final repo = ApiRepository(
      'https://api.invalid',
      client: MockClient(
        (_) async => http.Response.bytes(Uint8List(1048577), 200),
      ),
    );
    await repo.saveSession(session('a'));
    await expectLater(
      repo.receiptBytes('/receipts/r/media/i'),
      throwsA(isA<ApiFailure>()),
    );
    await repo.close();
  });
}
