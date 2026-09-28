import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/phone_auth.dart';
import 'package:hisaab/core/repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Json phoneSession(String account, {String token = 'current-token'}) => {
  'accessToken': token,
  'refreshToken': 'refresh-$account',
  'user': {'id': account},
};

PhoneChallenge currentChallenge() => PhoneChallenge(
  'phone-proof',
  DateTime.now().add(const Duration(minutes: 5)),
  30,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApiRepository repository;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) respond;
  var current = true;

  PhoneAuthService service({
    PhoneAuthPurpose purpose = PhoneAuthPurpose.signIn,
  }) =>
      PhoneAuthService(repository, purpose: purpose, isCurrent: () => current);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    requests = [];
    current = true;
    respond = (request) async {
      if (request.url.path.endsWith('/challenge')) {
        return http.Response(
          jsonEncode({
            'nonce': 'phone-proof',
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 5))
                .toUtc()
                .toIso8601String(),
            'resendAfterSeconds': 30,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode(phoneSession('account', token: 'verified-token')),
        200,
      );
    };
    repository = ApiRepository(
      'https://example.invalid',
      client: MockClient((request) async {
        requests.add(request);
        return respond(request);
      }),
    );
  });
  tearDown(() => repository.close());

  test(
    'normalizes international phone numbers and rejects ambiguous input',
    () {
      expect(
        PhoneAuthService.normalizePhone('  +91 (98765) 432-10  '),
        '+919876543210',
      );
      expect(
        PhoneAuthService.normalizePhone('+1 415 555 2671'),
        '+14155552671',
      );
      for (final input in [
        '',
        '9876543210',
        '00919876543210',
        '+0123456789',
        '+1234567',
        '+1234567890123456',
        '+91 98765 43210 ext 2',
      ]) {
        expect(
          () => PhoneAuthService.normalizePhone(input),
          throwsA(isA<ApiFailure>()),
          reason: input,
        );
      }
    },
  );

  for (final entry in {
    PhoneAuthPurpose.signIn: '/v1/auth/phone/challenge',
    PhoneAuthPurpose.link: '/v1/auth/phone/link/challenge',
    PhoneAuthPurpose.reauthenticate: '/v1/auth/phone/reauthenticate/challenge',
  }.entries) {
    test(
      '${entry.key.name} requests its purpose-specific phone challenge',
      () async {
        if (entry.key != PhoneAuthPurpose.signIn) {
          await repository.saveSession(phoneSession('account'));
        }
        final challenge = await service(
          purpose: entry.key,
        ).sendCode('+91 (98765) 43210');
        expect(requests.single.method, 'POST');
        expect(requests.single.url.path, entry.value);
        expect(jsonDecode(requests.single.body), {
          'phoneNumber': '+919876543210',
        });
        expect(challenge.nonce, 'phone-proof');
        expect(challenge.expiresAt.isAfter(DateTime.now()), isTrue);
        expect(challenge.resendAfterSeconds, 30);
        expect(
          requests.single.headers['Authorization'],
          entry.key == PhoneAuthPurpose.signIn
              ? isNull
              : 'Bearer current-token',
        );
      },
    );
  }

  test(
    'invalid phone numbers, codes, and expired proofs never reach the API',
    () async {
      final phone = service();
      await expectLater(
        phone.sendCode('9876543210'),
        throwsA(isA<ApiFailure>()),
      );
      for (final code in ['', '12345', '1234567', '12a456', ' 123456']) {
        await expectLater(
          phone.verify(currentChallenge(), code),
          throwsA(isA<ApiFailure>()),
        );
      }
      await expectLater(
        phone.verify(
          PhoneChallenge(
            'expired',
            DateTime.now().subtract(const Duration(seconds: 1)),
            0,
          ),
          '123456',
        ),
        throwsA(
          isA<ApiFailure>().having((e) => '$e', 'message', contains('expired')),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  for (final purpose in [PhoneAuthPurpose.signIn, PhoneAuthPurpose.link]) {
    test(
      '${purpose.name} returns a phone proof result without replacing the session',
      () async {
        if (purpose == PhoneAuthPurpose.link) {
          await repository.saveSession(phoneSession('account'));
        }
        final previousSession = repository.session;
        final savedBefore = await const FlutterSecureStorage().read(
          key: 'hisaab.session',
        );
        final result = await service(
          purpose: purpose,
        ).verify(currentChallenge(), '123456', name: '  Asha  ');
        expect(
          requests.single.url.path,
          purpose == PhoneAuthPurpose.signIn
              ? '/v1/auth/sign-in'
              : '/v1/auth/link',
        );
        expect(jsonDecode(requests.single.body), {
          'provider': 'phone',
          'nonce': 'phone-proof',
          'idToken': '123456',
          'displayName': 'Asha',
        });
        expect(result['accessToken'], 'verified-token');
        expect(repository.session, same(previousSession));
        expect(
          await const FlutterSecureStorage().read(key: 'hisaab.session'),
          savedBefore,
        );
      },
    );
  }

  test('omits an empty optional display name from the sign-in proof', () async {
    await service().verify(currentChallenge(), '123456', name: '  ');
    expect(jsonDecode(requests.single.body), {
      'provider': 'phone',
      'nonce': 'phone-proof',
      'idToken': '123456',
    });
  });

  test(
    'reauthentication persists a new session only for the current account',
    () async {
      await repository.saveSession(phoneSession('account'));
      final result = await service(
        purpose: PhoneAuthPurpose.reauthenticate,
      ).verify(currentChallenge(), '123456', name: 'Ignored name');
      expect(requests.single.url.path, '/v1/auth/phone/reauthenticate');
      expect(jsonDecode(requests.single.body), {
        'nonce': 'phone-proof',
        'code': '123456',
      });
      expect(repository.session, result);
      expect(repository.session?['accessToken'], 'verified-token');
      expect(
        jsonDecode(
          (await const FlutterSecureStorage().read(key: 'hisaab.session'))!,
        ),
        result,
      );
    },
  );

  test(
    'reauthentication cannot replace the current account with another account',
    () async {
      await repository.saveSession(phoneSession('account'));
      respond = (_) async =>
          http.Response(jsonEncode(phoneSession('other')), 200);
      await expectLater(
        service(
          purpose: PhoneAuthPurpose.reauthenticate,
        ).verify(currentChallenge(), '123456'),
        throwsA(
          isA<ApiFailure>().having(
            (e) => '$e',
            'message',
            contains('current account'),
          ),
        ),
      );
      expect(repository.session?['user']['id'], 'account');
      expect(repository.session?['accessToken'], 'current-token');
      expect(
        jsonDecode(
          (await const FlutterSecureStorage().read(key: 'hisaab.session'))!,
        )['user']['id'],
        'account',
      );
    },
  );

  for (final purpose in [
    PhoneAuthPurpose.link,
    PhoneAuthPurpose.reauthenticate,
  ]) {
    test(
      '${purpose.name} requires a signed-in account before making requests',
      () async {
        final phone = service(purpose: purpose);
        await expectLater(
          phone.sendCode('+919876543210'),
          throwsA(isA<ApiFailure>()),
        );
        await expectLater(
          phone.verify(currentChallenge(), '123456'),
          throwsA(isA<ApiFailure>()),
        );
        expect(requests, isEmpty);
      },
    );
  }

  for (final operation in ['challenge', 'verify']) {
    for (final change in [
      'different account',
      'same account new session',
      'cancelled flow',
    ]) {
      test('$operation rejects a response after $change', () async {
        await repository.saveSession(phoneSession('account'));
        final phone = service(purpose: PhoneAuthPurpose.reauthenticate);
        final received = Completer<void>();
        final response = Completer<http.Response>();
        respond = (_) {
          received.complete();
          return response.future;
        };
        final pending = operation == 'challenge'
            ? phone.sendCode('+919876543210')
            : phone.verify(currentChallenge(), '123456');
        final rejected = expectLater(pending, throwsA(isA<ApiFailure>()));
        await received.future;
        if (change == 'cancelled flow') {
          current = false;
        } else {
          await repository.saveSession(
            phoneSession(
              change == 'different account' ? 'other' : 'account',
              token: 'replacement-token',
            ),
          );
        }
        response.complete(
          http.Response(
            jsonEncode(
              operation == 'challenge'
                  ? {
                      'nonce': 'late-proof',
                      'expiresAt': DateTime.now()
                          .add(const Duration(minutes: 5))
                          .toUtc()
                          .toIso8601String(),
                      'resendAfterSeconds': 30,
                    }
                  : phoneSession('account', token: 'late-token'),
            ),
            200,
          ),
        );
        await rejected;
        expect(
          repository.session?['accessToken'],
          change == 'cancelled flow' ? 'current-token' : 'replacement-token',
        );
      });
    }
  }

  test(
    'wrong codes can be retried without refreshing the current session',
    () async {
      await repository.saveSession(phoneSession('account'));
      var attempts = 0;
      respond = (_) async => ++attempts == 1
          ? http.Response(
              '{"message":"Incorrect code","code":"phone_code_invalid"}',
              401,
            )
          : http.Response(
              jsonEncode(phoneSession('account', token: 'verified-token')),
              200,
            );
      final phone = service(purpose: PhoneAuthPurpose.reauthenticate);
      await expectLater(
        phone.verify(currentChallenge(), '111111'),
        throwsA(
          isA<ApiFailure>().having((e) => e.code, 'code', 'phone_code_invalid'),
        ),
      );
      await phone.verify(currentChallenge(), '123456');
      expect(requests.map((request) => request.url.path), [
        '/v1/auth/phone/reauthenticate',
        '/v1/auth/phone/reauthenticate',
      ]);
      expect(
        requests[0].headers['Idempotency-Key'],
        isNot(requests[1].headers['Idempotency-Key']),
      );
      expect(repository.session?['accessToken'], 'verified-token');
    },
  );

  for (final purpose in [
    PhoneAuthPurpose.link,
    PhoneAuthPurpose.reauthenticate,
  ]) {
    for (final operation in ['challenge', 'verify']) {
      test(
        '${purpose.name} $operation refreshes an expired access token before retrying',
        () async {
          await repository.saveSession(phoneSession('account'));
          final normalResponse = respond;
          final generation = repository.sessionGeneration;
          respond = (request) async {
            if (request.url.path == '/v1/auth/refresh') {
              return http.Response(
                jsonEncode(phoneSession('account', token: 'rotated-token')),
                200,
              );
            }
            if (request.headers['Authorization'] == 'Bearer current-token') {
              return http.Response(
                jsonEncode({
                  'message': 'Session expired',
                  'code': operation == 'challenge'
                      ? 'session_expired'
                      : 'session_invalid',
                }),
                401,
              );
            }
            return normalResponse(request);
          };
          final phone = service(purpose: purpose);
          if (operation == 'challenge') {
            expect(
              (await phone.sendCode('+919876543210')).nonce,
              'phone-proof',
            );
          } else {
            expect(
              (await phone.verify(currentChallenge(), '123456'))['accessToken'],
              'verified-token',
            );
          }
          expect(requests, hasLength(3));
          expect(requests[1].url.path, '/v1/auth/refresh');
          expect(jsonDecode(requests[1].body), {
            'refreshToken': 'refresh-account',
          });
          expect(requests[2].url.path, requests[0].url.path);
          expect(requests[2].body, requests[0].body);
          expect(
            requests[2].headers['Idempotency-Key'],
            requests[0].headers['Idempotency-Key'],
          );
          expect(requests[2].headers['Authorization'], 'Bearer rotated-token');
          final reauthenticated =
              purpose == PhoneAuthPurpose.reauthenticate &&
              operation == 'verify';
          expect(
            repository.sessionGeneration,
            generation + (reauthenticated ? 1 : 0),
          );
          expect(
            repository.session?['accessToken'],
            reauthenticated ? 'verified-token' : 'rotated-token',
          );
        },
      );
    }
  }

  for (final operation in ['challenge', 'verify']) {
    test(
      '$operation accepts a same-account token refresh while its response is pending',
      () async {
        await repository.saveSession(phoneSession('account'));
        final phone = service(purpose: PhoneAuthPurpose.link);
        final normalResponse = respond;
        final received = Completer<http.Request>();
        final response = Completer<http.Response>();
        var refreshed = false;
        respond = (request) async {
          if (request.url.path == '/v1/auth/refresh') {
            refreshed = true;
            return http.Response(
              jsonEncode(phoneSession('account', token: 'rotated-token')),
              200,
            );
          }
          if (request.url.path == '/v1/groups') {
            return refreshed
                ? http.Response('{"items":[]}', 200)
                : http.Response(
                    '{"message":"Session expired","code":"session_expired"}',
                    401,
                  );
          }
          received.complete(request);
          return response.future;
        };
        final generation = repository.sessionGeneration;
        final pending = operation == 'challenge'
            ? phone.sendCode('+919876543210')
            : phone.verify(currentChallenge(), '123456');
        final request = await received.future;
        await repository.request('GET', '/groups');
        expect(repository.session?['accessToken'], 'rotated-token');
        response.complete(await normalResponse(request));
        await pending;
        expect(repository.session?['accessToken'], 'rotated-token');
        expect(repository.sessionGeneration, generation);
      },
    );
  }

  for (final operation in ['challenge', 'verify']) {
    test('$operation can retry after a temporary network outage', () async {
      final normalResponse = respond;
      var attempts = 0;
      respond = (request) async {
        if (++attempts == 1) throw const SocketException('offline');
        return normalResponse(request);
      };
      final phone = service();
      Future<Object> request() => operation == 'challenge'
          ? phone.sendCode('+919876543210')
          : phone.verify(currentChallenge(), '123456');
      await expectLater(
        request(),
        throwsA(isA<ApiFailure>().having((e) => e.code, 'code', 'offline')),
      );
      expect(repository.offline, isTrue);
      await request();
      expect(attempts, 2);
      expect(repository.offline, isFalse);
      expect(
        requests[0].headers['Idempotency-Key'],
        isNot(requests[1].headers['Idempotency-Key']),
      );
    });
  }
}
