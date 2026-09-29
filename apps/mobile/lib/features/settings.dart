import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/config.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/native_services.dart';
import '../core/phone_auth.dart';
import '../core/repository.dart';
import '../main.dart';
import 'shared.dart';
import 'phone_sign_in.dart';
import 'spending.dart';

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
  Widget build(BuildContext context) {
    final name = (c.user['displayName'] as String?)?.trim();
    final displayName = name == null || name.isEmpty ? 'Your account' : name;
    return PageBody(
      children: [
        Text('Your space', style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 6),
        const Text(
          'Your account, your preferences.',
          style: TextStyle(color: HisaabColors.muted),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: HisaabColors.lilac,
              foregroundColor: HisaabColors.primary,
              child: Text(
                displayName.characters.first.toUpperCase(),
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    c.demo
                        ? 'Local demo · no real account'
                        : c.user['email'] ?? 'Personal account',
                    style: const TextStyle(color: HisaabColors.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              _AccountRow(
                icon: Icons.account_balance_wallet_outlined,
                color: HisaabColors.lime,
                title: 'Personal spending',
                subtitle: 'Private budgets, imports and data export',
                onTap: () => openPage(context, c, SpendingPage(controller: c)),
              ),
              const _AccountDivider(),
              _AccountRow(
                icon: Icons.notifications_rounded,
                title: 'Notifications',
                subtitle: 'Updates that matter to you',
                onTap: () => openPage(
                  context,
                  c,
                  NotificationSettingsPage(controller: c),
                ),
              ),
              const _AccountDivider(),
              _AccountRow(
                icon: Icons.link_rounded,
                color: HisaabColors.mint,
                title: 'Linked sign-in methods',
                subtitle: 'One account. More ways in.',
                onTap: () => linkIdentity(context),
              ),
              const _AccountDivider(),
              _AccountRow(
                icon: Icons.auto_awesome_rounded,
                color: HisaabColors.peach,
                title: 'Ad-free plan',
                subtitle: _planLabel(c),
                onTap: () => openPage(context, c, PremiumPage(controller: c)),
              ),
              const _AccountDivider(),
              _AccountRow(
                icon: Icons.shield_rounded,
                title: 'Privacy & your data',
                subtitle: 'Your information, your choices',
                onTap: () =>
                    openPage(context, c, _PrivacySettingsPage(settings: this)),
              ),
            ],
          ),
        ),
        const SectionTitle('More'),
        Card(
          child: Column(
            children: [
              _AccountRow(
                icon: Icons.tune_rounded,
                color: HisaabColors.surface,
                title: 'Manage subscription',
                subtitle: 'View or change your plan',
                onTap: () => openLink(context, AppConfig.subscriptionUrl),
              ),
              const _AccountDivider(),
              _AccountRow(
                icon: Icons.logout_rounded,
                color: HisaabColors.peach,
                title: c.demo ? 'Leave demo' : 'Sign out',
                subtitle: 'Sign out from this device',
                onTap: () => act(context, c.logout),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Hisaab · INR · 1.0.0',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: HisaabColors.muted),
        ),
      ],
    );
  }

  Future<void> linkIdentity(BuildContext context) async {
    if (c.demo) {
      message(context, 'Account linking needs a signed-in account.');
      return;
    }
    final account = c.userId;
    final repo = c.repository;
    final provider = await _chooseProvider(
      context,
      title: 'One account. More ways in.',
      description:
          'Choose the method you want to add. We’ll first confirm your current account, then verify the new method.',
      action: 'Link',
      icon: Icons.link_rounded,
    );
    if (provider == null || !context.mounted) return;
    final currentProvider = await _chooseProvider(
      context,
      title: 'Confirm your current account',
      description:
          'Choose a sign-in method already linked to this Hisaab account.',
      action: 'Continue with',
      icon: Icons.verified_user_outlined,
    );
    if (currentProvider == null || !context.mounted) return;
    await act(context, () async {
      if (repo is! ApiRepository ||
          c.userId != account ||
          !identical(c.repository, repo)) {
        throw ApiFailure('Account changed. Start linking again from Account.');
      }
      await _reauthenticate(context, repo, currentProvider, account);
      if (c.userId != account || !identical(c.repository, repo)) {
        throw ApiFailure('Account changed. Start linking again from Account.');
      }
      if (!context.mounted) return;
      if (provider == 'phone') {
        await _phoneVerification(context, repo, PhoneAuthPurpose.link, account);
      } else {
        final proof = await c.identity.credential(repo, provider);
        if (c.userId != account || !identical(c.repository, repo)) {
          throw ApiFailure(
            'Account changed. Start linking again from Account.',
          );
        }
        await repo.request('POST', '/auth/link', proof);
      }
      await c.refresh();
      if (context.mounted) {
        message(context, 'Sign-in method linked to this account.');
      }
    });
  }

  Future<void> _phoneVerification(
    BuildContext context,
    ApiRepository repo,
    PhoneAuthPurpose purpose,
    String account,
  ) async {
    final result = await openPage<Json>(
      context,
      c,
      PhoneSignInPage(
        service: PhoneAuthService(
          repo,
          purpose: purpose,
          isCurrent: () => c.userId == account && identical(c.repository, repo),
        ),
      ),
    );
    if (result == null) throw IdentityCancelled();
  }

  Future<void> _reauthenticate(
    BuildContext context,
    ApiRepository repo,
    String provider,
    String account,
  ) => provider == 'phone'
      ? _phoneVerification(
          context,
          repo,
          PhoneAuthPurpose.reauthenticate,
          account,
        )
      : c.identity.reauthenticate(repo, provider, account);

  Future<void> deleteAccount(BuildContext context) async {
    final confirmDelete = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(
                child: CircleAvatar(
                  radius: 32,
                  backgroundColor: HisaabColors.peach,
                  child: Icon(
                    Icons.lock_outline_rounded,
                    color: HisaabColors.warning,
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                c.demo ? 'Reset the demo?' : 'Delete your account?',
                textAlign: TextAlign.center,
                style: Theme.of(ctx).textTheme.headlineMedium,
              ),
              const SizedBox(height: 14),
              Text(
                c.demo
                    ? 'This removes this device’s demo expenses and returns to the welcome screen.'
                    : 'Your personal account data will be removed. Shared financial history remains for other members under “Deleted user”, and outstanding balances remain recorded.',
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.5),
              ),
              const SizedBox(height: 16),
              const Text(
                'Deleting an account does not cancel a store subscription.',
                textAlign: TextAlign.center,
                style: TextStyle(color: HisaabColors.muted, height: 1.5),
              ),
              TextButton(
                onPressed: () => openLink(ctx, AppConfig.subscriptionUrl),
                child: const Text('Manage store subscription'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep account'),
              ),
              const SizedBox(height: 10),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  foregroundColor: HisaabColors.warning,
                  backgroundColor: HisaabColors.peach,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(c.demo ? 'Reset demo' : 'Delete account'),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmDelete != true || !context.mounted) return;
    final account = c.userId;
    final repo = c.repository;
    String? provider;
    if (!c.demo) {
      provider = await _chooseProvider(
        context,
        title: 'Confirm your identity',
        description:
            'Use a sign-in method already linked to this account to confirm deletion.',
        action: 'Continue with',
        icon: Icons.verified_user_outlined,
      );
      if (provider == null || !context.mounted) return;
    }
    await act(context, () async {
      if (provider != null) {
        await _reauthenticate(
          context,
          repo as ApiRepository,
          provider,
          account,
        );
      }
      if (c.userId != account || !identical(c.repository, repo)) {
        throw ApiFailure('Account changed. Start deletion again from Account.');
      }
      await c.request('DELETE', '/me', {'confirm': true});
      await c.logout(deleted: true);
    });
  }
}

class NotificationSettingsPage extends StatelessWidget {
  final AppController controller;
  const NotificationSettingsPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: PageBody(
        children: [
          const _SettingsHeading(
            title: 'Stay in the loop',
            subtitle: 'Get notified about what matters.',
            icon: Icons.notifications_active_rounded,
          ),
          const SizedBox(height: 24),
          Card(
            child: Column(
              children: [
                for (final entry in const [
                  (
                    'expenses',
                    'Expense updates',
                    'When shared expenses change',
                    Icons.groups_rounded,
                    HisaabColors.mint,
                  ),
                  (
                    'payments',
                    'Payment updates',
                    'When someone records a payment',
                    Icons.arrow_forward_rounded,
                    HisaabColors.peach,
                  ),
                  (
                    'invites',
                    'Invitations',
                    'When you’re invited to a group',
                    Icons.person_add_alt_1_rounded,
                    HisaabColors.lilac,
                  ),
                  (
                    'receiptDetails',
                    'Receipt details on lock screen',
                    'Include item names and amounts.',
                    Icons.lock_outline_rounded,
                    HisaabColors.surface,
                  ),
                ]) ...[
                  if (entry.$1 != 'expenses') const _AccountDivider(),
                  SwitchListTile.adaptive(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    secondary: MediaQuery.textScalerOf(context).scale(16) > 24
                        ? null
                        : _AccountIcon(entry.$4, color: entry.$5),
                    title: Text(entry.$2),
                    subtitle: Text(entry.$3),
                    value:
                        controller.preferences[entry.$1] ??
                        (entry.$1 != 'receiptDetails'),
                    onChanged: controller.offline
                        ? null
                        : (enabled) => act(context, () async {
                            await controller.request(
                              'PATCH',
                              '/me/preferences',
                              {...controller.preferences, entry.$1: enabled},
                            );
                            await controller.refresh();
                          }),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: _AccountRow(
              icon: Icons.tune_rounded,
              color: HisaabColors.surface,
              title: 'Enable push on this device',
              subtitle: 'Choose delivery in device settings.',
              onTap: () => act(context, () async {
                if (controller.demo) {
                  message(context, 'Sign in to enable device notifications.');
                  return;
                }
                await controller.push.enable(
                  controller.repository!,
                  () => controller.refresh(),
                );
                if (context.mounted) {
                  message(context, 'Device notification settings updated.');
                }
              }),
            ),
          ),
        ],
      ),
    ),
  );
}

class _PrivacySettingsPage extends StatelessWidget {
  final SettingsPage settings;
  const _PrivacySettingsPage({required this.settings});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacy & your data')),
    body: PageBody(
      children: [
        const _SettingsHeading(
          title: 'You’re in control',
          subtitle: 'A little clarity about your information.',
          icon: Icons.shield_rounded,
        ),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              _AccountRow(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacy & ad choices',
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
              const _AccountDivider(),
              _AccountRow(
                icon: Icons.policy_outlined,
                color: HisaabColors.mint,
                title: 'Privacy policy',
                onTap: () => openLink(context, AppConfig.privacyUrl),
              ),
              const _AccountDivider(),
              _AccountRow(
                icon: Icons.description_outlined,
                color: HisaabColors.mint,
                title: 'Terms of use',
                onTap: () => openLink(context, AppConfig.termsUrl),
              ),
            ],
          ),
        ),
        const SectionTitle('Account data'),
        Card(
          child: _AccountRow(
            icon: Icons.delete_outline_rounded,
            title: settings.c.demo ? 'Reset demo data' : 'Delete account',
            subtitle: settings.c.demo
                ? 'Start your demo again'
                : 'Review what happens before you decide',
            destructive: true,
            onTap: () => settings.deleteAccount(context),
          ),
        ),
      ],
    ),
  );
}

class _SettingsHeading extends StatelessWidget {
  final String title, subtitle;
  final IconData icon;
  const _SettingsHeading({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: const TextStyle(color: HisaabColors.muted, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Transform.rotate(
          angle: -.12,
          child: ExcludeSemantics(
            child: CircleAvatar(
              radius: 26,
              backgroundColor: HisaabColors.lilac,
              child: Icon(icon, color: HisaabColors.primary, size: 28),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AccountDivider extends StatelessWidget {
  const _AccountDivider();
  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, indent: 66, endIndent: 16);
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
    setState(() {
      loading = true;
      error = null;
      packages = [];
    });
    final account = c.userId;
    try {
      if (!c.demo && c.billing.readyFor(account)) {
        final available = await c.billing.packages(account);
        if (account == c.userId && mounted) packages = available;
      }
    } catch (e) {
      if (mounted && account == c.userId) error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Ad-free plan')),
      body: PageBody(
        children: [
          Text(
            'A little more calm',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Same Hisaab you love. No ads.',
            style: TextStyle(color: HisaabColors.muted, height: 1.5),
          ),
          const SizedBox(height: 20),
          const EditorialArtwork(asset: HisaabArt.together, height: 180),
          if (c.adFree) ...[
            const SizedBox(height: 18),
            _AccountNotice(
              icon: Icons.verified_outlined,
              color: HisaabColors.mint,
              title: _planLabel(c),
              body: c.entitlement['adFree'] == true
                  ? c.entitlement['expiresAt'] == null
                        ? 'Your account’s ad-free access is active.'
                        : 'Access until ${c.entitlement['expiresAt'].toString().split('T').first}.'
                  : 'Ads are paused while your store purchase is verified.',
            ),
          ],
          const SizedBox(height: 20),
          Card(
            color: HisaabColors.lilac,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Yearly',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'All the essentials stay free.',
                    style: TextStyle(color: HisaabColors.muted),
                  ),
                  const SizedBox(height: 20),
                  const _PlanBenefit(
                    icon: Icons.block_outlined,
                    title: 'No banner ads',
                  ),
                  const _PlanBenefit(
                    icon: Icons.devices_outlined,
                    title: 'One account, all your devices',
                  ),
                  const Divider(height: 28),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: CircularProgressIndicator(
                          semanticsLabel: 'Loading store price',
                        ),
                      ),
                    )
                  else if (packages.isEmpty) ...[
                    Text(
                      c.demo
                          ? 'Try the experience in this demo. Sign in to see the store’s current annual price.'
                          : 'The annual price is unavailable right now. Check your store account, then try again.',
                      style: const TextStyle(height: 1.5),
                    ),
                    if (!c.demo) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: busy || c.offline ? null : load,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Reload store price'),
                      ),
                    ],
                  ] else
                    for (final package in packages) ...[
                      Text.rich(
                        TextSpan(
                          text: package.storeProduct.priceString,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w600,
                            color: HisaabColors.ink,
                          ),
                          children: const [
                            TextSpan(
                              text: ' / year',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w400,
                                color: HisaabColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
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
                            c.adFree
                                ? 'Ad-free on this account'
                                : 'Choose yearly',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  const SizedBox(height: 12),
                  const Text(
                    'Renews yearly. Cancel in your store. No trial.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: HisaabColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          OutlinedButton(
            onPressed: busy ? null : () => Navigator.of(context).maybePop(),
            child: Text(c.adFree ? 'Back to account' : 'Keep using free'),
          ),
          const SizedBox(height: 18),
          const _AccountNotice(
            icon: Icons.favorite_border_rounded,
            color: HisaabColors.mint,
            title: 'Everyday sharing stays free',
            body:
                'Expense splitting and receipt attachments are included on the free plan.',
          ),
          const SizedBox(height: 16),
          if (busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Checking your store purchase',
                ),
              ),
            ),
          OutlinedButton.icon(
            onPressed:
                busy ||
                    loading ||
                    c.demo ||
                    !c.billing.readyFor(c.userId) ||
                    c.offline
                ? null
                : restore,
            icon: const Icon(Icons.restore_rounded),
            label: const Text('Restore purchases'),
          ),
          if (c.billingMessage != null) ...[
            const SizedBox(height: 16),
            _AccountNotice(
              icon: Icons.info_outline_rounded,
              color: HisaabColors.mint,
              title: 'Purchase status',
              body: c.billingMessage!,
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: _AccountNotice(
                icon: Icons.info_outline_rounded,
                color: HisaabColors.peach,
                title: 'We couldn’t complete that',
                body: error!,
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            'How annual billing works',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Payment is charged to your store account. Your subscription renews automatically unless canceled in store settings before renewal. Cancel at any time; access continues until the paid period ends.',
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: HisaabColors.muted,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 4,
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
                child: const Text('Manage subscription'),
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

String _planLabel(AppController c) {
  if (!c.adFree) return 'Free plan';
  if (c.entitlement['adFree'] != true) return 'Store verification pending';
  return 'Ad-free is active';
}

class _AccountIcon extends StatelessWidget {
  final IconData icon;
  final bool destructive;
  final Color color;
  const _AccountIcon(
    this.icon, {
    this.destructive = false,
    this.color = HisaabColors.lilac,
  });
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: destructive ? HisaabColors.peach : color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        color: destructive ? clay : HisaabColors.primary,
        size: 20,
      ),
    ),
  );
}

class _AccountRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool destructive;
  final Color color;
  const _AccountRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
    this.color = HisaabColors.lilac,
  });
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    leading: _AccountIcon(icon, destructive: destructive, color: color),
    title: Text(title, style: TextStyle(color: destructive ? clay : null)),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const ExcludeSemantics(
      child: Icon(Icons.chevron_right_rounded, color: HisaabColors.muted),
    ),
    onTap: onTap,
  );
}

class _AccountNotice extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title, body;
  const _AccountNotice({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(icon, color: HisaabColors.ink)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(body, style: const TextStyle(height: 1.5)),
      ],
    ),
  );
}

class _PlanBenefit extends StatelessWidget {
  final IconData icon;
  final String title;
  const _PlanBenefit({required this.icon, required this.title});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(icon, color: HisaabColors.primary, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ],
    ),
  );
}

Future<String?> _chooseProvider(
  BuildContext context, {
  required String title,
  required String description,
  required String action,
  required IconData icon,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                color: HisaabColors.lilac,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 44, color: HisaabColors.primary),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(height: 1.5, color: HisaabColors.muted),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(context, 'apple'),
            icon: const Icon(Icons.apple_rounded),
            label: Text('$action Apple'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, 'google'),
            icon: const Icon(Icons.g_mobiledata_rounded, size: 28),
            label: Text('$action Google'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: HisaabColors.lilac,
              foregroundColor: HisaabColors.primary,
            ),
            onPressed: () => Navigator.pop(context, 'phone'),
            icon: const Icon(Icons.phone_outlined),
            label: Text('$action phone'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Not now'),
          ),
        ],
      ),
    ),
  ),
);
