// The plugin's native message codec is needed to mock its real platform channel.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:google_mobile_ads/src/ad_instance_manager.dart';
import 'package:hisaab/core/ads.dart';
import 'package:hisaab/core/config.dart';
import 'package:hisaab/core/controller.dart';

// Run this configuration matrix with ADS_ENABLED, ADS_POLICY_REVIEWED and an
// ADMOB_ANDROID_BANNER_ID compile flag. Every native call below is mocked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled =
      AppConfig.adsEnabled &&
      const bool.fromEnvironment('ADS_POLICY_REVIEWED') &&
      AppConfig.bannerId.isNotEmpty;
  late ConsentInformation previousConsent;
  late PendingConsent consent;
  late AppController controller;
  final calls = <String>[];
  Completer<void>? configurationGate, initializationGate;
  bool failConfiguration = false;

  setUp(() {
    previousConsent = ConsentInformation.instance;
    consent = PendingConsent();
    ConsentInformation.instance = consent;
    controller = AppController()..entitlement = {'adFree': false};
    calls.clear();
    configurationGate = null;
    initializationGate = null;
    failConfiguration = false;
    instanceManager = AdInstanceManager('plugins.flutter.io/google_mobile_ads');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(instanceManager.channel, (call) async {
          calls.add(call.method);
          if (call.method == 'MobileAds#updateRequestConfiguration') {
            final values = call.arguments as Map;
            expect(values['maxAdContentRating'], MaxAdContentRating.g);
            expect(
              values['ageRestrictedTreatment'],
              AgeRestrictedTreatment.child.index,
            );
            if (failConfiguration) {
              throw PlatformException(code: 'configuration_failed');
            }
            await configurationGate?.future;
          }
          if (call.method == 'MobileAds#initialize') {
            await initializationGate?.future;
            return InitializationStatus({});
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/google_mobile_ads/ump'),
          (call) async {
            calls.add(call.method);
            return null;
          },
        );
  });

  tearDown(() {
    controller.dispose();
    ConsentInformation.instance = previousConsent;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(instanceManager.channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/google_mobile_ads/ump'),
          null,
        );
  });

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SafeBanner(controller: controller, route: 'home'),
      ),
    ),
  );
  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
  }

  testWidgets('consent completing on protected route cannot skip SDK policy', (
    tester,
  ) async {
    await mount(tester);
    controller.protect(true);
    consent.allowed.complete(true);
    await flush(tester);
    expect(calls, contains('MobileAds#updateRequestConfiguration'));
    expect(calls, contains('MobileAds#initialize'));
    expect(calls, isNot(contains('loadBannerAd')));
    controller.protect(false);
    await flush(tester);
    expect(calls.where((call) => call == 'loadBannerAd'), hasLength(1));
    expect(
      calls.indexOf('MobileAds#updateRequestConfiguration'),
      lessThan(calls.indexOf('MobileAds#initialize')),
    );
    expect(
      calls.indexOf('MobileAds#initialize'),
      lessThan(calls.indexOf('loadBannerAd')),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !enabled);

  testWidgets('controller changes cannot load before SDK setup finishes', (
    tester,
  ) async {
    configurationGate = Completer<void>();
    initializationGate = Completer<void>();
    await mount(tester);
    consent.allowed.complete(true);
    await flush(tester);
    controller.selectTab(0);
    await flush(tester);
    expect(calls, isNot(contains('MobileAds#initialize')));
    expect(calls, isNot(contains('loadBannerAd')));
    configurationGate!.complete();
    await flush(tester);
    controller.selectTab(0);
    await flush(tester);
    expect(calls, contains('MobileAds#initialize'));
    expect(calls, isNot(contains('loadBannerAd')));
    initializationGate!.complete();
    await flush(tester);
    expect(calls.where((call) => call == 'loadBannerAd'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !enabled);

  testWidgets('SDK policy failure keeps the ad slot closed', (tester) async {
    failConfiguration = true;
    await mount(tester);
    consent.allowed.complete(true);
    await flush(tester);
    controller.selectTab(0);
    await flush(tester);
    expect(calls, isNot(contains('loadBannerAd')));
    expect(calls, isNot(contains('MobileAds#initialize')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !enabled);

  testWidgets('premium activation during setup prevents a queued banner', (
    tester,
  ) async {
    initializationGate = Completer<void>();
    await mount(tester);
    consent.allowed.complete(true);
    await flush(tester);
    controller.entitlement = {'adFree': true};
    controller.selectTab(0);
    initializationGate!.complete();
    await flush(tester);
    expect(calls, isNot(contains('loadBannerAd')));
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !enabled);
}

class PendingConsent implements ConsentInformation {
  final allowed = Completer<bool>();
  @override
  void requestConsentInfoUpdate(
    ConsentRequestParameters params,
    OnConsentInfoUpdateSuccessListener successListener,
    OnConsentInfoUpdateFailureListener failureListener,
  ) => successListener();
  @override
  Future<bool> canRequestAds() => allowed.future;
  @override
  Future<ConsentStatus> getConsentStatus() async => ConsentStatus.obtained;
  @override
  Future<PrivacyOptionsRequirementStatus>
  getPrivacyOptionsRequirementStatus() async =>
      PrivacyOptionsRequirementStatus.notRequired;
  @override
  Future<bool> isConsentFormAvailable() async => false;
  @override
  Future<void> reset() async {}
}
