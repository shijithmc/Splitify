import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/core/models.dart';
import 'package:hisaab/core/phone_auth.dart';
import 'package:hisaab/core/repository.dart';
import 'package:hisaab/features/phone_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late ApiRepository repository;
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) respond;
  Json? result;
  var returned = false;
  var cooldown = 0;
  var challenges = 0;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    requests = [];
    result = null;
    returned = false;
    cooldown = 0;
    challenges = 0;
    respond = (request) async {
      if (request.url.path.endsWith('/challenge')) {
        return http.Response(
          jsonEncode({
            'nonce': 'challenge-${++challenges}',
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 5))
                .toUtc()
                .toIso8601String(),
            'resendAfterSeconds': cooldown,
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'accessToken': 'verified-token',
          'refreshToken': 'verified-refresh',
          'user': {'id': 'account'},
        }),
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

  Future<void> open(
    WidgetTester tester, {
    PhoneAuthPurpose purpose = PhoneAuthPurpose.signIn,
  }) async {
    if (purpose != PhoneAuthPurpose.signIn) {
      await repository.saveSession({
        'accessToken': 'current-token',
        'refreshToken': 'current-refresh',
        'user': {'id': 'account'},
      });
    }
    final service = PhoneAuthService(
      repository,
      purpose: purpose,
      isCurrent: () => true,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<Json>(
                  MaterialPageRoute(
                    builder: (_) => PhoneSignInPage(service: service),
                  ),
                );
                returned = true;
              },
              child: const Text('Open phone verification'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open phone verification'));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> sendCode(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('phone-number')),
      '+91 98765 43210',
    );
    await tapVisible(tester, 'Send code');
  }

  testWidgets(
    'phone sign-in sends a normalized number and returns the verified result',
    (tester) async {
      await open(tester);
      expect(find.text('Sign in with your phone'), findsOneWidget);
      expect(
        find.textContaining('then link your phone in Settings'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('phone-display-name')),
        '  Asha  ',
      );
      await sendCode(tester);
      expect(find.text('Check your messages'), findsOneWidget);
      expect(
        find.text('Enter the 6-digit code sent to +919876543210.'),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('phone-code')), '123456');
      await tapVisible(tester, 'Verify and sign in');
      expect(returned, isTrue);
      expect(result?['user']['id'], 'account');
      expect(repository.session, isNull);
      expect(jsonDecode(requests.first.body), {'phoneNumber': '+919876543210'});
      expect(jsonDecode(requests.last.body), {
        'provider': 'phone',
        'nonce': 'challenge-1',
        'idToken': '123456',
        'displayName': 'Asha',
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resend replaces the proof and clears the previously entered code',
    (tester) async {
      await open(tester);
      await sendCode(tester);
      await tester.enterText(find.byKey(const Key('phone-code')), '111111');
      await tapVisible(tester, 'Resend code');
      expect(challenges, 2);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('phone-code')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(find.byKey(const Key('phone-code')), '123456');
      await tapVisible(tester, 'Verify and sign in');
      expect(jsonDecode(requests.last.body)['nonce'], 'challenge-2');
    },
  );

  testWidgets('resend cooldown survives changing the phone number', (
    tester,
  ) async {
    cooldown = 30;
    await open(tester);
    await sendCode(tester);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Resend code in 30s'),
          )
          .onPressed,
      isNull,
    );
    await tapVisible(tester, 'Change phone number');
    expect(find.byKey(const Key('phone-number')), findsOneWidget);
    expect(find.byKey(const Key('phone-code')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Send code in 30s'),
          )
          .onPressed,
      isNull,
    );
    expect(challenges, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'wrong code stays on the form and a corrected code can be retried',
    (tester) async {
      final normalResponse = respond;
      respond = (request) async {
        if (request.url.path == '/v1/auth/sign-in' &&
            jsonDecode(request.body)['idToken'] == '111111') {
          return http.Response(
            '{"message":"Incorrect code. Please try again.","code":"invalid_otp"}',
            401,
          );
        }
        return normalResponse(request);
      };
      await open(tester);
      await sendCode(tester);
      await tester.enterText(find.byKey(const Key('phone-code')), '111111');
      await tapVisible(tester, 'Verify and sign in');
      expect(find.text('Incorrect code. Please try again.'), findsOneWidget);
      expect(returned, isFalse);
      await tester.enterText(find.byKey(const Key('phone-code')), '123456');
      await tapVisible(tester, 'Verify and sign in');
      expect(returned, isTrue);
      expect(result?['accessToken'], 'verified-token');
    },
  );

  testWidgets('a failed send displays a recoverable error and allows retry', (
    tester,
  ) async {
    final normalResponse = respond;
    var attempts = 0;
    respond = (request) async {
      if (++attempts == 1) throw const SocketException('offline');
      return normalResponse(request);
    };
    await open(tester);
    await sendCode(tester);
    expect(find.textContaining('Connection unavailable'), findsOneWidget);
    expect(find.byKey(const Key('phone-number')), findsOneWidget);
    await tapVisible(tester, 'Send code');
    expect(find.textContaining('Connection unavailable'), findsNothing);
    expect(find.byKey(const Key('phone-code')), findsOneWidget);
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('back cancels verification without submitting a proof', (
    tester,
  ) async {
    await open(tester);
    await sendCode(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    expect(result, isNull);
    expect(requests, hasLength(1));
    expect(repository.session, isNull);
  });

  testWidgets(
    'pending send disables duplicate submission and back navigation',
    (tester) async {
      final response = Completer<http.Response>();
      final normalResponse = respond;
      respond = (_) => response.future;
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('phone-number')),
        '+919876543210',
      );
      await tapVisible(tester, 'Send code');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Please wait…'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<TextField>(find.byKey(const Key('phone-number'))).enabled,
        isFalse,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(returned, isFalse);
      response.complete(await normalResponse(requests.single));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('phone-code')), findsOneWidget);
      expect(requests, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final entry in {
    PhoneAuthPurpose.link: 'Link your phone number',
    PhoneAuthPurpose.reauthenticate: 'Confirm your account',
  }.entries) {
    testWidgets(
      '${entry.key.name} uses account-specific instructions without a display-name field',
      (tester) async {
        await open(tester, purpose: entry.key);
        expect(find.text(entry.value), findsOneWidget);
        expect(find.byKey(const Key('phone-display-name')), findsNothing);
        if (entry.key == PhoneAuthPurpose.reauthenticate) {
          expect(
            find.text('Use a phone number already linked to this account.'),
            findsOneWidget,
          );
        }
        await sendCode(tester);
        expect(find.text('Verify phone number'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'phone and code forms remain scrollable with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await open(tester);
      await sendCode(tester);
      expect(find.byKey(const Key('phone-code')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Change phone number'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Change phone number'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('phone-number')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
