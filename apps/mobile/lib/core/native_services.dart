import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:uuid/uuid.dart';
import 'config.dart';
import 'models.dart';
import 'repository.dart';

class IdentityService {
  bool _googleReady = false;
  Future<Json> credential(ApiRepository repo, String provider) async {
    final challenge = await repo.request('GET', '/auth/challenge');
    final nonce = challenge['nonce'] as String;
    if (provider == 'google') {
      if (AppConfig.googleServerId.isEmpty) {
        throw ApiFailure('Google sign-in is not configured for this build.');
      }
      if (!_googleReady) {
        // v7 allows initialization exactly once; its nonce cannot rotate safely.
        // Server validates Google issuer, audience, lifetime and one-use challenge.
        await GoogleSignIn.instance.initialize(
          clientId: AppConfig.googleClientId.isEmpty
              ? null
              : AppConfig.googleClientId,
          serverClientId: AppConfig.googleServerId,
        );
        _googleReady = true;
      }
      final account = await GoogleSignIn.instance.authenticate();
      final token = account.authentication.idToken;
      if (token == null) {
        throw ApiFailure('Google did not return an identity token.');
      }
      return {
        'provider': provider,
        'idToken': token,
        'nonce': nonce,
        if (account.displayName?.trim().isNotEmpty == true)
          'displayName': account.displayName!.trim(),
      };
    }
    if (Platform.isAndroid &&
        (AppConfig.appleClientId.isEmpty || AppConfig.appleRedirect.isEmpty)) {
      throw ApiFailure(
        'Apple sign-in on Android needs its web callback configuration.',
      );
    }
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: sha256.convert(utf8.encode(nonce)).toString(),
      state: nonce,
      webAuthenticationOptions: Platform.isAndroid
          ? WebAuthenticationOptions(
              clientId: AppConfig.appleClientId,
              redirectUri: Uri.parse(AppConfig.appleRedirect),
            )
          : null,
    );
    if (credential.state != nonce) {
      throw ApiFailure('Apple sign-in state did not match. Please try again.');
    }
    if (credential.identityToken == null) {
      throw ApiFailure('Apple did not return an identity token.');
    }
    return {
      'provider': provider,
      'idToken': credential.identityToken,
      'nonce': nonce,
      'authorizationCode': credential.authorizationCode,
      if ([
        credential.givenName,
        credential.familyName,
      ].whereType<String>().join(' ').trim().isNotEmpty)
        'displayName': [
          credential.givenName,
          credential.familyName,
        ].whereType<String>().join(' ').trim(),
    };
  }

  Future<void> reauthenticate(
    ApiRepository repo,
    String provider,
    String accountId,
  ) async {
    final proof = await credential(repo, provider);
    final session = await repo.request('POST', '/auth/sign-in', proof);
    if (session['user']['id'] != accountId) {
      throw ApiFailure(
        'That sign-in belongs to a different Hisaab account. Choose your current account to continue.',
      );
    }
    await repo.saveSession(session);
  }

  Future<void> signOut() async {
    if (_googleReady) await GoogleSignIn.instance.signOut();
  }
}

abstract interface class BillingSdk {
  Future<bool> isConfigured();
  Future<void> configure(String key, String userId);
  Future<void> logIn(String userId);
  Future<void> logOut();
  Future<String> currentUserId();
  Future<List<Package>> packages();
  Future<bool> purchase(Package package);
  Future<bool> restore();
  Future<bool> active();
}

class RevenueCatSdk implements BillingSdk {
  @override
  Future<bool> isConfigured() => Purchases.isConfigured;
  @override
  Future<void> configure(String key, String userId) =>
      Purchases.configure(PurchasesConfiguration(key)..appUserID = userId);
  @override
  Future<void> logIn(String userId) async {
    await Purchases.logIn(userId);
  }

  @override
  Future<void> logOut() async {
    await Purchases.logOut();
  }

  @override
  Future<String> currentUserId() => Purchases.appUserID;
  @override
  Future<List<Package>> packages() async =>
      (await Purchases.getOfferings()).current?.availablePackages
          .where((p) => p.packageType == PackageType.annual)
          .toList() ??
      [];
  @override
  Future<bool> purchase(Package package) async => (await Purchases.purchase(
    PurchaseParams.package(package),
  )).customerInfo.entitlements.active.containsKey('ad_free');
  @override
  Future<bool> restore() async => (await Purchases.restorePurchases())
      .entitlements
      .active
      .containsKey('ad_free');
  @override
  Future<bool> active() async {
    await Purchases.invalidateCustomerInfoCache();
    return (await Purchases.getCustomerInfo()).entitlements.active.containsKey(
      'ad_free',
    );
  }
}

/// Every SDK operation is serialized and bound to a verified Hisaab identity.
/// Transitions invalidate usability synchronously, even when native calls fail.
class BillingService {
  final BillingSdk sdk;
  final String apiKey;
  final bool supported;
  Future<void> _tail = Future.value();
  String? _account;
  int _generation = 0;
  BillingService({BillingSdk? sdk, String? apiKey, bool? supported})
    : sdk = sdk ?? RevenueCatSdk(),
      apiKey = apiKey ?? AppConfig.revenueCatKey,
      supported = supported ?? (Platform.isIOS || Platform.isAndroid);
  bool readyFor(String expected) => expected.isNotEmpty && _account == expected;
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> identify(String userId) {
    final generation = ++_generation;
    _account = null;
    return _serial(() async {
      if (generation != _generation || !supported || apiKey.isEmpty) return;
      try {
        if (!await sdk.isConfigured()) {
          await sdk.configure(apiKey, userId);
        } else {
          await sdk.logIn(userId);
        }
        final actual = await sdk.currentUserId();
        if (generation != _generation) return;
        if (actual != userId) {
          throw ApiFailure(
            'Store identity did not match this Hisaab account. Sign in again before purchasing.',
          );
        }
        _account = userId;
      } catch (_) {
        if (generation == _generation) _account = null;
        rethrow;
      }
    });
  }

  Future<void> _verify(String expected, int generation) async {
    try {
      if (generation != _generation || !readyFor(expected)) {
        throw ApiFailure(
          'Purchases are unavailable until this Hisaab account is verified with the store.',
        );
      }
      final actual = await sdk.currentUserId();
      if (generation != _generation ||
          !readyFor(expected) ||
          actual != expected) {
        throw ApiFailure(
          'Your account changed. Sign in again before purchasing.',
        );
      }
    } catch (_) {
      if (generation == _generation) _account = null;
      rethrow;
    }
  }

  Future<T> _forAccount<T>(String expected, Future<T> Function() action) {
    final generation = _generation;
    return _serial(() async {
      await _verify(expected, generation);
      final result = await action();
      await _verify(expected, generation);
      return result;
    });
  }

  Future<List<Package>> packages(String expected) =>
      _forAccount(expected, sdk.packages);
  Future<bool> purchase(String expected, Package package) =>
      _forAccount(expected, () => sdk.purchase(package));
  Future<bool> restore(String expected) => _forAccount(expected, sdk.restore);
  Future<bool> storeEntitlementActive(String expected) =>
      _forAccount(expected, sdk.active);
  Future<void> signOut() {
    ++_generation;
    _account = null;
    return _serial(() async {
      if (await sdk.isConfigured()) await sdk.logOut();
    });
  }
}

class PushService {
  StreamSubscription<String>? _tokens;
  StreamSubscription<RemoteMessage>? _messages;
  StreamSubscription<RemoteMessage>? _opened;
  void Function(Json)? onOpen;
  String? _deviceId;
  Future<void> enable(Repository repo, void Function() refresh) async {
    if (!AppConfig.pushEnabled || repo.isDemo) {
      throw ApiFailure('Push needs a configured signed-in build.');
    }
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    await FirebaseMessaging.instance.requestPermission();
    final prefs = await SharedPreferences.getInstance();
    _deviceId = prefs.getString('hisaab.device') ?? const Uuid().v4();
    await prefs.setString('hisaab.device', _deviceId!);
    Future<void> register(String token) async =>
        repo.request('POST', '/devices', {
          'id': _deviceId,
          'token': token,
          'platform': Platform.isIOS ? 'ios' : 'android',
        });
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await register(token);
    await _tokens?.cancel();
    await _messages?.cancel();
    await _opened?.cancel();
    _tokens = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      unawaited(register(token).catchError((Object _) {}));
    });
    _messages = FirebaseMessaging.onMessage.listen((_) => refresh());
    _opened = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => onOpen?.call(message.data),
    );
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) onOpen?.call(initial.data);
  }

  Future<void> reconnect(Repository repo, void Function() refresh) async {
    if (!AppConfig.pushEnabled || repo.isDemo) return;
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    final permission = await FirebaseMessaging.instance
        .getNotificationSettings();
    if (permission.authorizationStatus == AuthorizationStatus.authorized ||
        permission.authorizationStatus == AuthorizationStatus.provisional) {
      await enable(repo, refresh);
    }
  }

  Future<void> disconnect(Repository repo) async {
    await _tokens?.cancel();
    await _messages?.cancel();
    await _opened?.cancel();
    onOpen = null;
    _deviceId ??= (await SharedPreferences.getInstance()).getString(
      'hisaab.device',
    );
    if (_deviceId != null) {
      try {
        await repo.request('DELETE', '/devices/$_deviceId');
      } catch (_) {}
    }
    _deviceId = null;
  }
}
