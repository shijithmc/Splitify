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
import 'spending.dart';
import 'spending_import.dart';

class AppController extends ChangeNotifier {
  Repository? repository;
  final identity = IdentityService();
  final BillingService billing;
  final SpendingImportService spendingImports;
  AppController({
    BillingService? billing,
    SpendingImportService? spendingImports,
  }) : billing = billing ?? BillingService(),
       spendingImports = spendingImports ?? SpendingImportService();
  int _accountEpoch = 0;
  SpendingController? _spending;
  Repository? _spendingRepository;
  bool _spendingClosing = false;
  Timer? _spendingPoll;
  bool _importingSpending = false;
  bool _clearingSpending = false;
  int _spendingGeneration = 0;
  bool _refreshingSpendingLinks = false;
  String? spendingImportError;
  bool get spendingAvailable => signedIn && !_spendingClosing;
  SpendingController get spending {
    if (_spendingClosing) {
      // Retain the already-cleared instance during native shutdown. A rebuild
      // must never lazily reopen the previous account's encrypted ledger.
      if (_spending != null) return _spending!;
      throw StateError('Personal spending session is changing.');
    }
    if (_spending != null &&
        (_spending!.account != userId ||
            !identical(_spendingRepository, repository))) {
      unawaited(_spending!.endSession());
      _spending = null;
    }
    _spendingRepository = repository;
    return _spending ??= SpendingController(account: userId, demo: demo);
  }

  Future<void> _initializeSpending() async {
    if (!signedIn) return;
    if (_spendingClosing) {
      _spending = null;
      _spendingRepository = null;
      _spendingClosing = false;
    }
    final epoch = _accountEpoch;
    final personal = spending;
    await personal.initialize();
    if (epoch != _accountEpoch || !signedIn) return;
    try {
      await spendingImports.configureOwner(demo ? null : userId);
      if (epoch != _accountEpoch || !signedIn) return;
      if (!demo) await syncSpendingSms();
    } catch (_) {
      // Manual entries and local statements work without the SMS bridge.
    }
    if (epoch != _accountEpoch || !signedIn) return;
    _spendingPoll?.cancel();
    if (!demo) {
      _spendingPoll = Timer.periodic(const Duration(seconds: 30), (_) {
        if (foreground && signedIn) unawaited(syncSpendingSms());
      });
    }
  }

  Future<int> syncSpendingSms({bool requestPermission = false}) async {
    if (!spendingAvailable || demo || _importingSpending || _clearingSpending) {
      return 0;
    }
    final epoch = _accountEpoch;
    final generation = _spendingGeneration;
    final personal = spending;
    _importingSpending = true;
    try {
      if (!spendingImports.supportsSms) return 0;
      if (!requestPermission && !await spendingImports.smsEnabled()) return 0;
      final records = await spendingImports.importSms(
        requestPermission: requestPermission,
      );
      if (epoch != _accountEpoch ||
          generation != _spendingGeneration ||
          !signedIn) {
        return 0;
      }
      final added = await personal.importRows(records);
      if (epoch != _accountEpoch ||
          generation != _spendingGeneration ||
          !signedIn) {
        return added;
      }
      await spendingImports.acknowledgeSms();
      spendingImportError = null;
      return added;
    } catch (e) {
      if (epoch == _accountEpoch) spendingImportError = '$e';
      if (requestPermission) rethrow;
      return 0;
    } finally {
      _importingSpending = false;
    }
  }

  Future<void> clearPrivateSpending() async {
    final personal = spending;
    final epoch = _accountEpoch;
    ++_spendingGeneration;
    _clearingSpending = true;
    try {
      await spendingImports.disableSms();
      if (epoch != _accountEpoch) return;
      await spendingImports.clearImportedData();
      if (epoch != _accountEpoch) return;
      await personal.clear(discardPending: true);
      spendingImportError = null;
      notifyListeners();
    } finally {
      _clearingSpending = false;
    }
  }

  Future<void> refreshSpendingLinks() async {
    if (_spending == null ||
        !spendingAvailable ||
        offline ||
        _refreshingSpendingLinks) {
      return;
    }
    _refreshingSpendingLinks = true;
    final personal = _spending!;
    final epoch = _accountEpoch;
    try {
      for (final row in personal.transactions.where(
        (t) => t['expenseId'] != null,
      )) {
        if (epoch != _accountEpoch || !signedIn || offline) return;
        var review = false;
        int? share;
        try {
          final group = groups.where((g) => g.id == row['groupId']).firstOrNull;
          final me = group?.participant(userId);
          if (me == null) {
            review = true;
          } else {
            final expense = Expense(
              await request(
                'GET',
                '/groups/${row['groupId']}/expenses/${row['expenseId']}',
              ),
            );
            if (epoch != _accountEpoch || !signedIn || offline) return;
            review =
                expense.deleted ||
                expense.payer != me ||
                expense.amount != row['amountPaise'];
            if (!review) share = expense.shares[me] ?? 0;
          }
        } on ApiFailure catch (e) {
          if (epoch != _accountEpoch || !signedIn) return;
          if (e.status == 403 || e.status == 404) {
            review = true;
          } else {
            continue;
          }
        }
        if (epoch != _accountEpoch || !signedIn) return;
        if ((row['linkNeedsReview'] == true) != review ||
            (share != null && row['sharePaise'] != share)) {
          await personal.update(row['id'], {
            'linkNeedsReview': review,
            'sharePaise': ?share,
          });
        }
      }
    } catch (_) {
      // A failed refresh never replaces confirmed local data with a guess.
    } finally {
      _refreshingSpendingLinks = false;
    }
  }

  Future<void> _closeSpending({bool delete = false}) async {
    ++_spendingGeneration;
    _spendingClosing = true;
    _spendingPoll?.cancel();
    _spendingPoll = null;
    final personal = _spending;
    final closing = personal?.endSession(delete: delete);
    spendingImportError = null;
    notifyListeners();
    try {
      if (delete) {
        await spendingImports.disableSms();
        await spendingImports.clearImportedData();
      }
      await spendingImports.configureOwner(null);
    } catch (_) {
      // Unsupported platforms still close the encrypted local store.
    }
    await closing;
  }

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
    if (!signedIn) return;
    await _initializeSpending();
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

  Future<void> login(String provider) => _login((repo) async {
    final credential = await identity.credential(repo, provider);
    return repo.request('POST', '/auth/sign-in', credential);
  });

  Future<void> loginPhone(Future<Json?> Function(ApiRepository) verify) =>
      _login(verify);

  Future<void> _login(Future<Json?> Function(ApiRepository) verify) async {
    if (loading) return;
    final epoch = ++_accountEpoch;
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
      final session = await verify(repo);
      if (epoch != _accountEpoch) return;
      if (session != null) {
        await _closeSpending();
        await repo.saveSession(session);
        repository = repo;
        user = object(session['user']);
        entitlement = object(session['entitlement']);
        await refresh();
        await _nativeIdentity();
      }
    } on IdentityCancelled {
      // Closing the native account chooser returns to sign-in without an error.
    } catch (e) {
      if (epoch == _accountEpoch) error = '$e';
    }
    if (epoch == _accountEpoch) {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> startDemo() async {
    await _closeSpending();
    await _receipts?.endSession();
    _receipts = null;
    ++_accountEpoch;
    loading = true;
    error = null;
    notifyListeners();
    repository = await DemoRepository.open();
    user = object(repository!.session!['user']);
    await refresh();
    await _initializeSpending();
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
      if (method != 'GET' && path.startsWith('/groups/')) {
        unawaited(refreshSpendingLinks());
      }
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
      if (_spending != null) unawaited(syncSpendingSms());
      if (_spending != null) unawaited(refreshSpendingLinks());
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
    await _closeSpending(delete: deleted);
    loading = false;
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
    _spending = null;
    _spendingRepository = null;
    _spendingClosing = false;
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
    _spendingPoll?.cancel();
    unawaited(_spending?.endSession() ?? Future<void>.value());
    _billingRetry?.cancel();
    _provisionalExpiry?.cancel();
    unawaited(inviteLinks.dispose());
    super.dispose();
  }
}
