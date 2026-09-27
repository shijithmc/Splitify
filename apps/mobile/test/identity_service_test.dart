import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/native_services.dart';
import 'package:hisaab/core/repository.dart';
import 'package:hisaab/features/shared.dart';
import 'package:hisaab/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

class FakeGoogleAccount implements GoogleSignInAccount {
  const FakeGoogleAccount(this.token);
  final String? token;
  @override
  String get displayName => '  Asha  ';
  @override
  GoogleSignInAuthentication get authentication =>
      GoogleSignInAuthentication(idToken: token);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeGoogleSignIn implements GoogleSignIn {
  final calls = <String>[];
  String? initializedClient, initializedServer, token = 'google-id-token';
  Object? failure;
  Completer<void>? initialization;
  @override
  Future<void> initialize({
    String? clientId,
    String? serverClientId,
    String? nonce,
    String? hostedDomain,
  }) async {
    calls.add('initialize');
    initializedClient = clientId;
    initializedServer = serverClientId;
    await initialization?.future;
  }

  @override
  Future<GoogleSignInAccount> authenticate({
    List<String> scopeHint = const [],
  }) async {
    calls.add('authenticate');
    if (failure != null) throw failure!;
    return FakeGoogleAccount(token);
  }

  @override
  Future<void> signOut() async => calls.add('signOut');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAppleSignIn {
  String? sentNonce, sentState;
  List<AppleIDAuthorizationScopes>? scopes;
  WebAuthenticationOptions? options;
  String? returnedState, token = 'apple-id-token';
  bool omitNames = false;
  Object? failure;
  Completer<void>? pending;
  Future<AuthorizationCredentialAppleID> call({
    required List<AppleIDAuthorizationScopes> scopes,
    String? nonce,
    String? state,
    WebAuthenticationOptions? webAuthenticationOptions,
  }) async {
    sentNonce = nonce;
    sentState = state;
    this.scopes = scopes;
    options = webAuthenticationOptions;
    await pending?.future;
    if (failure != null) throw failure!;
    return AuthorizationCredentialAppleID(
      userIdentifier: 'apple-user',
      email: null,
      authorizationCode: 'one-use-code',
      identityToken: token,
      state: returnedState ?? state,
      givenName: omitNames ? null : 'Asha',
      familyName: omitNames ? null : 'Rao',
    );
  }
}

class SignInUiController extends AppController {
  void setLoading(bool value) {
    loading = value;
    notifyListeners();
  }
}

Json session(String id) => {
  'accessToken': 'session-$id',
  'refreshToken': 'refresh-$id',
  'user': {'id': id},
  'entitlement': {'adFree': false},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ApiRepository repo;
  late FakeGoogleSignIn google;
  late FakeAppleSignIn apple;
  late List<http.Request> requests;
  var challenges = 0;
  var signedInAccount = 'current';
  var tokenRefreshed = false;
  IdentityService identity({bool android = false}) => IdentityService(
    google: google,
    appleCredential: apple.call,
    googleClientId: 'ios-client',
    googleServerId: 'server-client',
    appleClientId: 'app.hisaab.service',
    appleRedirect: 'https://example.invalid/v1/auth/apple/callback',
    android: android,
  );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    google = FakeGoogleSignIn();
    apple = FakeAppleSignIn();
    requests = [];
    challenges = 0;
    signedInAccount = 'current';
    tokenRefreshed = false;
    repo = ApiRepository(
      'https://example.invalid',
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/v1/auth/challenge') {
          return http.Response(
            jsonEncode({'nonce': 'challenge-${++challenges}'}),
            200,
          );
        }
        if (request.url.path == '/v1/auth/sign-in') {
          return http.Response(jsonEncode(session(signedInAccount)), 200);
        }
        if (request.url.path == '/v1/auth/refresh') {
          tokenRefreshed = true;
          return http.Response(
            jsonEncode({...session('current'), 'accessToken': 'rotated'}),
            200,
          );
        }
        if (request.url.path == '/v1/groups') {
          return tokenRefreshed
              ? http.Response('{"items":[]}', 200)
              : http.Response('{"message":"Expired"}', 401);
        }
        throw StateError('Unexpected endpoint ${request.url.path}');
      }),
    );
  });
  tearDown(() => repo.close());

  test(
    'Google initializes once across services and signs out before each chooser',
    () async {
      final first = await identity().credential(repo, 'google');
      final second = await identity().credential(repo, 'google');
      expect(google.calls, [
        'initialize',
        'signOut',
        'authenticate',
        'signOut',
        'authenticate',
      ]);
      expect(google.initializedClient, 'ios-client');
      expect(google.initializedServer, 'server-client');
      expect(first, {
        'provider': 'google',
        'idToken': 'google-id-token',
        'nonce': 'challenge-1',
        'displayName': 'Asha',
      });
      expect(second['nonce'], 'challenge-2');
    },
  );

  test(
    'overlapping requests cannot open multiple native provider prompts',
    () async {
      google.initialization = Completer<void>();
      final service = identity();
      final first = service.credential(repo, 'google');
      while (google.calls.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectLater(
        service.credential(repo, 'apple'),
        throwsA(isA<ApiFailure>()),
      );
      expect(challenges, 1);
      expect(google.calls, ['initialize']);
      google.initialization!.complete();
      await first;
      expect(google.calls, ['initialize', 'signOut', 'authenticate']);
    },
  );

  for (final provider in ['google', 'apple']) {
    test(
      '$provider cancellation is distinct from failure and permits retry',
      () async {
        google.failure = const GoogleSignInException(
          code: GoogleSignInExceptionCode.canceled,
        );
        apple.failure = const SignInWithAppleAuthorizationException(
          code: AuthorizationErrorCode.canceled,
          message: 'Native cancel',
        );
        final service = identity();
        await expectLater(
          service.credential(repo, provider),
          throwsA(isA<IdentityCancelled>()),
        );
        expect(
          requests.every((r) => r.url.path == '/v1/auth/challenge'),
          isTrue,
        );
        google.failure = null;
        apple.failure = null;
        expect(
          (await service.credential(repo, provider))['nonce'],
          'challenge-2',
        );
      },
    );
    test('$provider rejects missing ID tokens', () async {
      google.token = '';
      apple.token = null;
      await expectLater(
        identity().credential(repo, provider),
        throwsA(isA<ApiFailure>()),
      );
    });
    test(
      '$provider failure does not expose native diagnostic payloads',
      () async {
        google.failure = const GoogleSignInException(
          code: GoogleSignInExceptionCode.unknownError,
          details: 'native-private-details',
        );
        apple.failure = const SignInWithAppleAuthorizationException(
          code: AuthorizationErrorCode.failed,
          message: 'native-private-details',
        );
        await expectLater(
          identity().credential(repo, provider),
          throwsA(
            isA<ApiFailure>().having(
              (e) => '$e',
              'message',
              isNot(contains('native-private-details')),
            ),
          ),
        );
      },
    );
  }

  test(
    'Apple uses a hashed nonce, matching state and configured Android callback',
    () async {
      final proof = await identity(android: true).credential(repo, 'apple');
      expect(
        apple.sentNonce,
        sha256.convert(utf8.encode('challenge-1')).toString(),
      );
      expect(apple.sentState, 'challenge-1');
      expect(apple.scopes, [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ]);
      expect(apple.options!.clientId, 'app.hisaab.service');
      expect(
        apple.options!.redirectUri.toString(),
        'https://example.invalid/v1/auth/apple/callback',
      );
      expect(proof, {
        'provider': 'apple',
        'idToken': 'apple-id-token',
        'nonce': 'challenge-1',
        'authorizationCode': 'one-use-code',
        'displayName': 'Asha Rao',
      });
    },
  );

  test(
    'Apple subsequent sign-in accepts absent first-authorization name',
    () async {
      apple.omitNames = true;
      final proof = await identity().credential(repo, 'apple');
      expect(proof.containsKey('displayName'), isFalse);
      expect(apple.options, isNull);
    },
  );

  test('Apple state mismatch is rejected before session exchange', () async {
    apple.returnedState = 'different';
    await expectLater(
      identity().credential(repo, 'apple'),
      throwsA(isA<ApiFailure>()),
    );
    expect(requests.length, 1);
  });

  test(
    'invalid provider configuration fails before requesting a challenge',
    () async {
      for (final entry in [
        (IdentityService(google: google, googleServerId: ''), 'google'),
        (
          IdentityService(
            appleCredential: apple.call,
            android: true,
            appleClientId: 'service',
            appleRedirect: 'http://example.invalid/callback',
          ),
          'apple',
        ),
        (identity(), 'unsupported'),
      ]) {
        await expectLater(
          entry.$1.credential(repo, entry.$2),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(requests, isEmpty);
      expect(google.calls, isEmpty);
      expect(apple.sentState, isNull);
    },
  );

  test(
    'reauthentication refuses another provider account without replacing session',
    () async {
      await repo.saveSession(session('current'));
      signedInAccount = 'other';
      final before = repo.session;
      await expectLater(
        identity().reauthenticate(repo, 'apple', 'current'),
        throwsA(isA<ApiFailure>()),
      );
      expect(identical(repo.session, before), isTrue);
      expect(
        jsonDecode(
          (await const FlutterSecureStorage().read(key: 'hisaab.session'))!,
        )['user']['id'],
        'current',
      );
    },
  );

  test(
    'account change while provider prompt is open cannot restore the old account',
    () async {
      await repo.saveSession(session('current'));
      apple.pending = Completer<void>();
      final attempt = identity().reauthenticate(repo, 'apple', 'current');
      final rejected = expectLater(attempt, throwsA(isA<ApiFailure>()));
      while (apple.sentState == null) {
        await Future<void>.delayed(Duration.zero);
      }
      await repo.saveSession(session('replacement'));
      apple.pending!.complete();
      await rejected;
      expect(repo.session!['user']['id'], 'replacement');
      expect(requests.any((r) => r.url.path == '/v1/auth/sign-in'), isFalse);
    },
  );

  test(
    'same-account token refresh during native prompt permits reauthentication',
    () async {
      await repo.saveSession(session('current'));
      apple.pending = Completer<void>();
      final attempt = identity().reauthenticate(repo, 'apple', 'current');
      while (apple.sentState == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final generation = repo.sessionGeneration;
      await repo.request('GET', '/groups');
      expect(tokenRefreshed, isTrue);
      expect(repo.sessionGeneration, generation);
      apple.pending!.complete();
      await attempt;
      expect(repo.session!['user']['id'], 'current');
      expect(requests.any((r) => r.url.path == '/v1/auth/sign-in'), isTrue);
    },
  );

  test(
    'sign-out during native prompt cannot reopen the closed repository',
    () async {
      await repo.saveSession(session('current'));
      apple.pending = Completer<void>();
      final attempt = identity().reauthenticate(repo, 'apple', 'current');
      final rejected = expectLater(attempt, throwsA(isA<ApiFailure>()));
      while (apple.sentState == null) {
        await Future<void>.delayed(Duration.zero);
      }
      await repo.close();
      apple.pending!.complete();
      await rejected;
      expect(repo.session, isNull);
      expect(
        await const FlutterSecureStorage().read(key: 'hisaab.session'),
        isNull,
      );
      expect(requests.any((r) => r.url.path == '/v1/auth/sign-in'), isFalse);
    },
  );

  testWidgets(
    'native sign-in loading preserves the provider picker after cancellation',
    (tester) async {
      final controller = SignInUiController()..loading = false;
      await tester.pumpWidget(HisaabApp(controller: controller));
      await tester.scrollUntilVisible(find.text('Find your people'), 300);
      await tester.tap(find.text('Find your people'));
      await tester.pumpAndSettle();
      controller.setLoading(true);
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ModalBarrier && widget.color == const Color(0x66FFFFFF),
        ),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      controller.setLoading(false);
      await tester.pumpAndSettle();
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with Apple'), findsOneWidget);
      expect(find.text('Find your people'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'canceling a provider prompt leaves account action UI without an error',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () => act(context, () async {
                    throw IdentityCancelled();
                  }),
                  child: const Text('Link account'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Link account'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
