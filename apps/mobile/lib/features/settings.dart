import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/config.dart';
import '../core/controller.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../main.dart';
import 'shared.dart';

Future<void> openLink(BuildContext context, String url) async {
  if (url.isEmpty) {
    message(context, 'This build needs its public legal URLs configured.');
    return;
  }
  await act(context, () async {
    if (!await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    )) {
      throw ApiFailure('Could not open this link.');
    }
  });
}

class SettingsPage extends StatelessWidget {
  final AppController controller;
  const SettingsPage({super.key, required this.controller});
  AppController get c => controller;
  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      const SectionTitle('Make yourself at home'),
      Card(
        child: ListTile(
          contentPadding: const EdgeInsets.all(20),
          leading: CircleAvatar(
            radius: 26,
            backgroundColor: const Color(0xFFDDE8D5),
            child: Text(
              (c.user['displayName'] as String? ?? 'Y').characters.first,
              style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600),
            ),
          ),
          title: Text(
            c.user['displayName'] ?? 'Your account',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            c.demo
                ? 'Local demo · no real account'
                : c.user['email'] ?? 'Private account',
          ),
        ),
      ),
      const SizedBox(height: 18),
      InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => openPage(context, c, PremiumPage(controller: c)),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: ink,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.spa_outlined,
                color: Color(0xFFDAE4AC),
                size: 36,
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c.adFree
                          ? 'A little more peace'
                          : 'Hisaab, without the ads',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      c.adFree
                          ? 'Ad-free · ${c.entitlement['status'] ?? 'Active'}'
                          : 'All the clarity. None of the interruptions.',
                      style: const TextStyle(
                        color: Color(0xFFCDDDCE),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward, color: Colors.white, size: 20),
            ],
          ),
        ),
      ),
      const SectionTitle('Notifications'),
      Card(
        child: Column(
          children: [
            for (final entry in {
              'expenses': 'Expense updates',
              'payments': 'Payment updates',
              'invites': 'Invitations',
            }.entries)
              SwitchListTile(
                title: Text(entry.value),
                value: c.preferences[entry.key] ?? true,
                onChanged: c.offline
                    ? null
                    : (enabled) => act(context, () async {
                        await c.request('PATCH', '/me/preferences', {
                          ...c.preferences,
                          entry.key: enabled,
                        });
                        await c.refresh();
                      }),
              ),
            ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Enable push on this device'),
              subtitle: const Text(
                'Control lock-screen delivery in device settings.',
              ),
              onTap: () => act(context, () async {
                await c.push.enable(c.repository!, () => c.refresh());
                if (context.mounted) {
                  message(context, 'Device notification settings updated.');
                }
              }),
            ),
          ],
        ),
      ),
      const SectionTitle('Your account'),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Link a sign-in method'),
              subtitle: const Text('Use your same account on another device.'),
              onTap: () => linkIdentity(context),
            ),
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined),
              title: const Text('Manage subscription'),
              onTap: () => openLink(context, AppConfig.subscriptionUrl),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy & ad choices'),
              onTap: () => act(context, () async {
                if (!AppConfig.adsEnabled) {
                  message(context, 'Ads are disabled in this build.');
                  return;
                }
                await ConsentForm.showPrivacyOptionsForm((error) {
                  if (error != null && context.mounted) {
                    message(context, error.message);
                  }
                });
              }),
            ),
            ListTile(
              leading: const Icon(Icons.policy_outlined),
              title: const Text('Privacy policy'),
              onTap: () => openLink(context, AppConfig.privacyUrl),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Terms of use'),
              onTap: () => openLink(context, AppConfig.termsUrl),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: Text(c.demo ? 'Leave demo' : 'Sign out'),
              onTap: () => act(context, c.logout),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: clay),
              title: Text(
                c.demo ? 'Reset demo data' : 'Delete account',
                style: const TextStyle(color: clay),
              ),
              onTap: () => deleteAccount(context),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const Text(
        'Made for shared moments.\nHisaab · INR · 1.0.0',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, height: 1.8, color: Color(0xFF728071)),
      ),
    ],
  );
  Future<void> linkIdentity(BuildContext context) async {
    if (c.demo) {
      message(context, 'Account linking needs a signed-in account.');
      return;
    }
    final provider = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Link another sign-in'),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              'Reauthenticate with your current provider first, then prove ownership of the method you want to link.',
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'google'),
            child: const Text('Link Google'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'apple'),
            child: const Text('Link Apple'),
          ),
        ],
      ),
    );
    if (provider == null || !context.mounted) return;
    final currentProvider = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Confirm your current account'),
        children: [
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Choose a sign-in method already linked to this Hisaab account.',
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'google'),
            child: const Text('Reauthenticate with Google'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'apple'),
            child: const Text('Reauthenticate with Apple'),
          ),
        ],
      ),
    );
    if (currentProvider == null || !context.mounted) return;
    await act(context, () async {
      await c.identity.reauthenticate(
        c.repository as ApiRepository,
        currentProvider,
        c.userId,
      );
      final proof = await c.identity.credential(
        c.repository as ApiRepository,
        provider,
      );
      await c.request('POST', '/auth/link', proof);
      await c.refresh();
      if (context.mounted) {
        message(context, 'Sign-in method linked to this account.');
      }
    });
  }

  Future<void> deleteAccount(BuildContext context) async {
    final confirmDelete = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c.demo ? 'Reset the demo?' : 'Delete your account?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                c.demo
                    ? 'This removes this device’s demo expenses and returns to the welcome screen.'
                    : 'Your personal account data will be removed. Shared financial history remains for other members under “Deleted user”, and outstanding balances remain recorded.',
              ),
              const SizedBox(height: 16),
              const Text(
                'Deleting an account does not cancel a store subscription.',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              TextButton(
                onPressed: () => openLink(ctx, AppConfig.subscriptionUrl),
                child: const Text('Manage store subscription'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep account'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(c.demo ? 'Reset demo' : 'Delete account'),
          ),
        ],
      ),
    );
    if (confirmDelete != true || !context.mounted) return;
    final account = c.userId;
    final repo = c.repository;
    String? provider;
    if (!c.demo) {
      provider = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Confirm your identity'),
          children: [
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Use a sign-in method already linked to this account to confirm deletion.',
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'google'),
              child: const Text('Continue with Google'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'apple'),
              child: const Text('Continue with Apple'),
            ),
          ],
        ),
      );
      if (provider == null || !context.mounted) return;
    }
    await act(context, () async {
      if (provider != null) {
        await c.identity.reauthenticate(
          repo as ApiRepository,
          provider,
          account,
        );
      }
      if (c.userId != account || !identical(c.repository, repo)) {
        throw ApiFailure(
          'Account changed. Start deletion again from Settings.',
        );
      }
      await c.request('DELETE', '/me', {'confirm': true});
      await c.logout(deleted: true);
    });
  }
}

class PremiumPage extends StatefulWidget {
  final AppController controller;
  const PremiumPage({super.key, required this.controller});
  @override
  State<PremiumPage> createState() => _PremiumPageState();
}

class _PremiumPageState extends State<PremiumPage> {
  List<Package> packages = [];
  bool loading = true, busy = false;
  String? error;
  AppController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final account = c.userId;
      if (!c.demo && c.billing.readyFor(account)) {
        final available = await c.billing.packages(account);
        if (account == c.userId && mounted) packages = available;
      }
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('A little more peace')),
      body: PageBody(
        children: [
          const SizedBox(height: 24),
          Center(
            child: Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                color: const Color(0xFFDEE7CD),
                borderRadius: BorderRadius.circular(36),
              ),
              child: const Icon(Icons.spa_outlined, size: 60, color: green),
            ),
          ),
          const SizedBox(height: 26),
          const Text(
            'Your moments.\nUninterrupted.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w700,
              letterSpacing: -1.2,
              height: 1.12,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Keep Hisaab ad-free, wherever you sign in.\nEvery expense-splitting feature stays free.',
            textAlign: TextAlign.center,
            style: TextStyle(height: 1.7, fontSize: 15),
          ),
          const SizedBox(height: 28),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.block, color: green),
                    title: Text('No banner or interstitial ads'),
                  ),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.devices, color: green),
                    title: Text('One Hisaab account, all your devices'),
                  ),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.all_inclusive, color: green),
                    title: Text('Unlimited everyday splitting'),
                  ),
                  if (c.adFree) ...[
                    const Divider(),
                    Text(
                      'Ad-free · ${c.entitlement['status'] ?? 'Verification pending'}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (c.entitlement['expiresAt'] != null)
                      Text(
                        'Valid until ${c.entitlement['expiresAt'].toString().split('T').first}',
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          if (loading)
            const Center(child: CircularProgressIndicator())
          else if (packages.isEmpty)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFEBECDD),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                c.demo
                    ? 'Purchases are unavailable in the local demo. Sign in with a configured build to view the store’s current annual price.'
                    : 'No annual store offering is available. Check your store account or try again later.',
                textAlign: TextAlign.center,
              ),
            )
          else
            ...packages.map(
              (package) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: FilledButton(
                  onPressed:
                      busy ||
                          !c.billing.readyFor(c.userId) ||
                          c.offline ||
                          c.adFree ||
                          AppConfig.termsUrl.isEmpty ||
                          AppConfig.privacyUrl.isEmpty
                      ? null
                      : () => purchase(package),
                  child: Text(
                    '${package.storeProduct.priceString} / year · Go ad-free',
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          TextButton(
            onPressed:
                busy || c.demo || !c.billing.readyFor(c.userId) || c.offline
                ? null
                : restore,
            child: const Text('Restore purchases'),
          ),
          if (c.billingMessage != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(c.billingMessage!, textAlign: TextAlign.center),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: const TextStyle(color: clay),
                textAlign: TextAlign.center,
              ),
            ),
          const Text(
            'Annual subscription. Payment is charged to your store account. It renews automatically unless canceled in store settings before renewal. You can cancel at any time; access continues until the paid period ends. No trial.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: Color(0xFF6D786B),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              TextButton(
                onPressed: () => openLink(context, AppConfig.termsUrl),
                child: const Text('Terms'),
              ),
              TextButton(
                onPressed: () => openLink(context, AppConfig.privacyUrl),
                child: const Text('Privacy'),
              ),
              TextButton(
                onPressed: () => openLink(context, AppConfig.subscriptionUrl),
                child: const Text('Manage'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Future<void> purchase(Package package) async {
    final account = c.userId;
    await perform(() async {
      final active = await c.billing.purchase(account, package);
      if (!mounted || account != c.userId) {
        throw ApiFailure('Account changed before purchase verification.');
      }
      await c.refreshBilling(expectedAccount: account, provisional: active);
      if (!c.adFree) {
        throw ApiFailure(
          'Purchase received. Store verification is pending; try restoring shortly.',
        );
      }
    });
  }

  Future<void> restore() async {
    final account = c.userId;
    await perform(() async {
      final active = await c.billing.restore(account);
      if (!mounted || account != c.userId) {
        throw ApiFailure('Account changed before purchase verification.');
      }
      await c.refreshBilling(expectedAccount: account, provisional: active);
      if (!c.adFree) {
        throw ApiFailure(
          'No verified ad-free purchase was found for this Hisaab account. Sign in to the account used for the original purchase.',
        );
      }
    });
  }

  Future<void> perform(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
      if (mounted) {
        message(
          context,
          c.entitlement['adFree'] == true
              ? 'Ad-free is active on your Hisaab account.'
              : 'Ads paused while store verification completes.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
