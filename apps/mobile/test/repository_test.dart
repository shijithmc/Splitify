import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Json session(String id, {String token = 'old'}) => {
  'accessToken': token,
  'refreshToken': 'refresh-$id',
  'user': {'id': id, 'displayName': id},
  'entitlement': {'adFree': false},
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'rotation retries one mutation with its original idempotency key',
    () async {
      final keys = <String?>[];
      var refreshes = 0;
      final repo = ApiRepository(
        'https://example.invalid',
        client: MockClient((request) async {
          if (request.url.path == '/v1/auth/refresh') {
            refreshes++;
            return http.Response(jsonEncode(session('a', token: 'new')), 200);
          }
          keys.add(request.headers['Idempotency-Key']);
          return request.headers['Authorization'] == 'Bearer old'
              ? http.Response('{"message":"Expired"}', 401)
              : http.Response('{"id":"group"}', 200);
        }),
      );
      await repo.saveSession(session('a'));
      expect(
        (await repo.request('POST', '/groups', {'name': 'Trip'}))['id'],
        'group',
      );
      expect(refreshes, 1);
      expect(keys.length, 2);
      expect(keys[0], isNotNull);
      expect(keys[0], keys[1]);
      await repo.close();
    },
  );
  test(
    'network failure uses account scoped read cache and disables writes',
    () async {
      var offline = false;
      final repo = ApiRepository(
        'https://example.invalid',
        client: MockClient((request) async {
          if (offline) throw const SocketException('offline');
          return http.Response('{"items":[{"id":"a-only"}]}', 200);
        }),
      );
      await repo.saveSession(session('a'));
      await repo.request('GET', '/groups');
      offline = true;
      expect(
        (await repo.request('GET', '/groups'))['items'][0]['id'],
        'a-only',
      );
      expect(repo.offline, isTrue);
      await expectLater(
        repo.request('POST', '/groups', {}),
        throwsA(isA<ApiFailure>().having((e) => e.code, 'code', 'offline')),
      );
      await repo.close();
      final storage = const FlutterSecureStorage();
      expect(await storage.read(key: 'hisaab.cache.a'), isNull);
      expect(await storage.read(key: 'hisaab.session'), isNull);
    },
  );
  test('switching accounts clears prior snapshots', () async {
    var offline = false;
    final repo = ApiRepository(
      'https://example.invalid',
      client: MockClient((request) async {
        if (offline) throw const SocketException('offline');
        return http.Response('{"private":"a"}', 200);
      }),
    );
    await repo.saveSession(session('a'));
    await repo.request('GET', '/me');
    await repo.saveSession(session('b'));
    offline = true;
    await expectLater(repo.request('GET', '/me'), throwsA(isA<ApiFailure>()));
    expect(
      await const FlutterSecureStorage().read(key: 'hisaab.cache.a'),
      isNull,
    );
    await repo.close();
  });
}
