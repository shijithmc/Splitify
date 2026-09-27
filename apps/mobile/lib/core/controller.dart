import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'config.dart';
import 'demo_repository.dart';
import 'invite_links.dart';
import 'models.dart';
import 'native_services.dart';
import 'repository.dart';
import 'receipts.dart';

class AppController extends ChangeNotifier {
  Repository? repository;
  final identity = IdentityService();
  final BillingService billing;
  AppController({BillingService? billing})
    : billing = billing ?? BillingService();
  int _accountEpoch = 0;
  ReceiptCoordinator? _receipts;
  ReceiptCoordinator get receipts {
    final repo = repository!;
    final account = userId, epoch = _accountEpoch;
    return _receipts ??= ReceiptCoordinator(
      repository: repo,
      account: account,
      current: () =>
          signedIn &&
          userId == account &&
          _accountEpoch == epoch &&
          identical(repository, repo),
      foreground: () => foreground,
    );
  }

  Json? pendingNotification;
  void receiveNotification(Json data) {
    if (!signedIn) return;
    if (data['groupId'] is! String || (data['groupId'] as String).isEmpty) {
      return;
    }
    pendingNotification = {...data, 'account': userId};
    notifyListeners();
  }

  Json? takeNotification() {
    final value = pendingNotification;
    pendingNotification = null;
    return value;
  }

  final push = PushService();
  final inviteLinks = InviteLinkService();
  final _secure = const FlutterSecureStorage();
  String? pendingInvite, billingMessage;
  bool loading = true, refreshing = false, foreground = true;
  String? error;
  Json user = {}, entitlement = {}, preferences = {}, balances = {};
  List<Group> groups = [];
  List<Json> activity = [], invites = [];
  int tab = 0, protectedDepth = 0;
  DateTime? provisionalUntil;
  Timer? _billingRetry, _provisionalExpiry;
  int _billingAttempts = 0;
  bool get signedIn => repository?.session != null;
  bool get demo => repository?.isDemo ?? false;
  bool get offline => repository?.offline ?? false;
  String get userId => user['id'] ?? '';
  bool get adFree {
    if (provisionalUntil?.isAfter(DateTime.now()) == true) return true;
    if (entitlement['adFree'] != true) return false;
    final expiry = DateTime.tryParse(entitlement['expiresAt'] ?? '');
    return expiry == null || expiry.isAfter(DateTime.now());
  }

  Future<void> initialize() async {
    try {
      pendingInvite = await _secure.read(key: 'hisaab.pendingInvite');
      await inviteLinks.start(receiveInvite);
    } catch (_) {
      /* Deep links do not block opening the app. */
    }
    if (AppConfig.configured) {
      final repo = ApiRepository(AppConfig.apiUrl);
      try {
        await repo.restore();
        repository = repo;
        if (repo.session != null) {
          user = object(repo.session!['user']);
          entitlement = object(repo.session!['entitlement']);
          await refresh();
          await _nativeIdentity();
        }
      } catch (e) {
        error = '$e';
      }
    }
    loading = false;
    notifyListeners();
  }

  Future<void> receiveInvite(String token) async {
    if (token == pendingInvite) return;
    pendingInvite = token;
    await _secure.write(key: 'hisaab.pendingInvite', value: token);
    notifyListeners();
  }

  Future<void> dismissInvite() async {
    pendingInvite = null;
    await _secure.delete(key: 'hisaab.pendingInvite');
    notifyListeners();
  }

  Future<void> _nativeIdentity() async {
    if (demo || !signedIn) return;
    final account = userId;
    final epoch = _accountEpoch;
    final repo = repository;
    try {
      await billing.identify(account);
    } catch (_) {
      /* Ledger works without store configuration. */
    }
    if (epoch != _accountEpoch ||
        account != userId ||
        !identical(repo, repository)) {
      return;
    }
    try {
      push.onOpen = receiveNotification;
      await push.reconnect(repository!, () => refresh());
    } catch (_) {
      /* Permission/configuration stays visible in Settings. */
    }
    await restoreBillingState();
    if (epoch == _accountEpoch &&
        account == userId &&
        identical(repo, repository)) {
      unawaited(receipts.initialize().catchError((Object _) {}));
    }
  }

  Future<void> restoreBillingState() async {
    if (!signedIn || demo) return;
    final account = userId;
    if (entitlement['adFree'] == true) {
      await _clearProvisional();
      return;
    }
    final saved = await _secure.read(key: 'hisaab.provisional.$account');
    if (account != userId) return;
    provisionalUntil = DateTime.tryParse(saved ?? '');
    if (provisionalUntil != null) {
      _setExpiryTimer();
      _scheduleBillingRetry();
      notifyListeners();
    }
  }

  Future<void> login(String provider) async {
    if (loading) return;
    ++_accountEpoch;
    loading = true;
    error = null;
    notifyListeners();
    try {
      if (!AppConfig.configured) {
        throw ApiFailure(
          'This build needs API_BASE_URL before signing in. Try the local demo below.',
        );
      }
      final repo = repository is ApiRepository
          ? repository as ApiRepository
          : ApiRepository(AppConfig.apiUrl);
      final credential = await identity.credential(repo, provider);
      final session = await repo.request('POST', '/auth/sign-in', credential);
      await repo.saveSession(session);
      repository = repo;
      user = object(session['user']);
      entitlement = object(session['entitlement']);
      await refresh();
      await _nativeIdentity();
    } on IdentityCancelled {
      // Closing the native account chooser returns to sign-in without an error.
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> startDemo() async {
    await _receipts?.endSession();
    _receipts = null;
    ++_accountEpoch;
    loading = true;
    error = null;
    notifyListeners();
    repository = await DemoRepository.open();
    user = object(repository!.session!['user']);
    await refresh();
    loading = false;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (repository == null || refreshing) return;
    refreshing = true;
    final repo = repository!;
    try {
      final values = await Future.wait([
        repo.request('GET', '/me'),
        repo.request('GET', '/groups'),
        repo.request('GET', '/balances'),
        repo.request('GET', '/activity'),
        repo.request('GET', '/invites'),
      ]);
      if (!identical(repository, repo)) return;
      user = object(values[0]['user']);
      entitlement = object(values[0]['entitlement']);
      preferences = object(values[0]['preferences']);
      groups = rows(values[1]['items']).map(Group.from).toList();
      balances = values[2];
      activity = rows(values[3]['items']);
      invites = rows(values[4]['items']);
      error = null;
      if (entitlement['adFree'] == true && provisionalUntil != null) {
        await _clearProvisional();
      }
      if (!offline && provisionalUntil != null) _scheduleBillingRetry();
    } catch (e) {
      if (!identical(repository, repo)) return;
      if (e is ApiFailure && e.status == 401) {
        await logout();
        error = 'Your session ended. Please sign in again.';
      } else {
        error = '$e';
      }
    }
    refreshing = false;
    notifyListeners();
  }

  Future<Json> request(String method, String path, [Json? data]) async {
    final repo = repository!;
    try {
      final result = await repo.request(method, path, data);
      notifyListeners();
      return result;
    } on ApiFailure catch (e) {
      if (e.status == 401 && identical(repository, repo)) await logout();
      rethrow;
    }
  }

  Future<void> refreshBilling({
    required String expectedAccount,
    bool provisional = false,
  }) async {
    if (expectedAccount != userId || !signedIn) {
      throw ApiFailure('Account changed before purchase verification.');
    }
    final account = expectedAccount;
    final repo = repository;
    final epoch = _accountEpoch;
    bool currentAccount() =>
        account == userId &&
        signedIn &&
        epoch == _accountEpoch &&
        identical(repository, repo);
    if (provisional && provisionalUntil == null) {
      // Only reached after a real SDK purchase/restore reports an active ad_free entitlement.
      provisionalUntil = DateTime.now().add(const Duration(hours: 24));
      await _secure.write(
        key: 'hisaab.provisional.$account',
        value: provisionalUntil!.toUtc().toIso8601String(),
      );
      if (!currentAccount()) return;
      billingMessage =
          'Your store purchase is being verified. Ads are paused for up to 24 hours.';
      _setExpiryTimer();
      notifyListeners();
    }
    try {
      final verified = await request('POST', '/billing/refresh');
      if (!currentAccount()) return;
      entitlement = verified;
      if (_receipts != null) {
        try {
          await _receipts!.refreshAllowance();
        } catch (_) {}
        if (!currentAccount()) return;
      }
      final status = (verified['status'] as String? ?? '').toLowerCase();
      if (verified['adFree'] == true ||
          [
            'revoked',
            'expired',
            'refunded',
            'sandbox_ignored',
            'ownership_mismatch',
          ].contains(status)) {
        await _clearProvisional();
      } else if (provisionalUntil != null) {
        // A successful free response can precede RevenueCat propagation of a
        // purchase the native SDK just verified. Keep only its original bound.
        _scheduleBillingRetry();
      }
    } catch (_) {
      if (currentAccount() && provisionalUntil != null) {
        _scheduleBillingRetry();
      }
      rethrow;
    }
    notifyListeners();
  }

  void _setExpiryTimer() {
    _provisionalExpiry?.cancel();
    final remaining = provisionalUntil!.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      billingMessage =
          'Purchase verification is still pending. Restore purchases or contact support using your Hisaab account.';
      return;
    }
    _provisionalExpiry = Timer(remaining, () {
      billingMessage =
          'Purchase verification is still pending. Restore purchases or contact support using your Hisaab account.';
      notifyListeners();
    });
  }

  void _scheduleBillingRetry() {
    if (_billingRetry != null ||
        !signedIn ||
        demo ||
        !foreground ||
        offline ||
        provisionalUntil == null) {
      return;
    }
    final account = userId;
    final seconds = math.min(300, 5 * (1 << math.min(_billingAttempts, 6)));
    _billingRetry = Timer(Duration(seconds: seconds), () async {
      _billingRetry = null;
      if (account != userId || !foreground || offline) return;
      _billingAttempts++;
      try {
        final storeActive = billing.readyFor(account)
            ? await billing.storeEntitlementActive(account)
            : null;
        if (account != userId || !signedIn) return;
        if (storeActive == false) {
          await _clearProvisional();
        }
        await refreshBilling(expectedAccount: account);
      } catch (_) {
        if (account == userId) _scheduleBillingRetry();
      }
    });
  }

  Future<void> _clearProvisional() async {
    _billingRetry?.cancel();
    _billingRetry = null;
    _provisionalExpiry?.cancel();
    _provisionalExpiry = null;
    provisionalUntil = null;
    billingMessage = null;
    _billingAttempts = 0;
    await _secure.delete(key: 'hisaab.provisional.$userId');
  }

  void setForeground(bool value) {
    foreground = value;
    if (!value) {
      _billingRetry?.cancel();
      _billingRetry = null;
    } else {
      _scheduleBillingRetry();
      if (_receipts != null) unawaited(_receipts!.pump());
    }
  }

  void protect(bool start) {
    protectedDepth += start ? 1 : -1;
    notifyListeners();
  }

  void selectTab(int value) {
    tab = value;
    notifyListeners();
  }

  Future<void> logout({bool deleted = false}) async {
    ++_accountEpoch;
    pendingNotification = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await _receipts?.endSession();
    _receipts = null;
    final storeSignOut = billing.signOut().then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await dismissInvite();
    await _clearProvisional();
    final repo = repository;
    repository = null;
    refreshing = false;
    if (repo != null) {
      await push.disconnect(repo);
      if (!deleted) {
        try {
          await repo.request('POST', '/auth/sign-out');
        } catch (_) {}
      }
      try {
        await storeSignOut;
        await identity.signOut();
      } catch (_) {}
      await repo.close();
    }
    user = {};
    entitlement = {};
    preferences = {};
    balances = {};
    groups = [];
    activity = [];
    invites = [];
    tab = 0;
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _billingRetry?.cancel();
    _provisionalExpiry?.cancel();
    unawaited(inviteLinks.dispose());
    super.dispose();
  }
}
