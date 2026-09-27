import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/config.dart';
import '../core/controller.dart';
import '../core/design.dart';
import '../core/receipts.dart';
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
  Widget build(BuildContext context) {
    final name = (c.user['displayName'] as String?)?.trim();
    final displayName = name == null || name.isEmpty ? 'Your account' : name;
    return PageBody(
      children: [
        const SectionTitle('Make yourself at home'),
        const Text(
          'Your account, your preferences, your peace of mind.',
          style: TextStyle(color: HisaabColors.muted, height: 1.5),
        ),
        const SizedBox(height: 22),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: HisaabColors.peach,
                  foregroundColor: HisaabColors.ink,
                  child: Text(
                    displayName.characters.first.toUpperCase(),
                    style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
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
                        style: const TextStyle(
                          fontFamily: 'Outfit',
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        c.demo
                            ? 'Local demo · no real account'
                            : c.user['email'] ?? 'Private account',
                        style: const TextStyle(
                          color: HisaabColors.muted,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          color: HisaabColors.lilac,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _AccountIcon(Icons.auto_awesome_outlined),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _planLabel(c),
                            style: const TextStyle(
                              fontFamily: 'Outfit',
                              fontSize: 21,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            c.adFree
                                ? 'More room for the moments that matter.'
                                : 'Everyday splitting stays free.',
                            style: const TextStyle(height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (c.signedIn) ...[
                  const SizedBox(height: 20),
                  _ScanAllowance(controller: c),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        openPage(context, c, PremiumPage(controller: c)),
                    icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                    label: Text(
                      c.adFree ? 'View your plan' : 'Explore ad-free',
                    ),
                  ),
                ),
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
                'receiptDetails': 'Receipt details on lock screen',
              }.entries)
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  title: Text(entry.value),
                  subtitle: entry.key == 'receiptDetails'
                      ? const Text('Include item names and amounts.')
                      : null,
                  value:
                      c.preferences[entry.key] ??
                      (entry.key != 'receiptDetails'),
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
              const Divider(height: 1, indent: 20, endIndent: 20),
              _AccountRow(
                icon: Icons.notifications_outlined,
                title: 'Enable push on this device',
                subtitle: 'Choose delivery in device settings.',
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
        const SectionTitle('Account & purchases'),
        Card(
          child: Column(
            children: [
              _AccountRow(
                icon: Icons.link_rounded,
                title: 'Link a sign-in method',
                subtitle: 'One account across your devices.',
                onTap: () => linkIdentity(context),
              ),
              _AccountRow(
                icon: Icons.manage_accounts_outlined,
                title: 'Manage subscription',
                subtitle: 'Review renewal in your store.',
                onTap: () => openLink(context, AppConfig.subscriptionUrl),
              ),
              _AccountRow(
                icon: Icons.logout_rounded,
                title: c.demo ? 'Leave demo' : 'Sign out',
                onTap: () => act(context, c.logout),
              ),
            ],
          ),
        ),
        const SectionTitle('Privacy & your data'),
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
              _AccountRow(
                icon: Icons.policy_outlined,
                title: 'Privacy policy',
                onTap: () => openLink(context, AppConfig.privacyUrl),
              ),
              _AccountRow(
                icon: Icons.description_outlined,
                title: 'Terms of use',
                onTap: () => openLink(context, AppConfig.termsUrl),
              ),
              _AccountRow(
                icon: Icons.delete_outline_rounded,
                title: c.demo ? 'Reset demo data' : 'Delete account',
                destructive: true,
                onTap: () => deleteAccount(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'Made for shared moments.\nHisaab · INR · 1.0.0',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.8,
            color: HisaabColors.muted,
          ),
        ),
      ],
    );
  }

  Future<void> linkIdentity(BuildContext context) async {
    if (c.demo) {
      message(context, 'Account linking needs a signed-in account.');
      return;
    }
    final provider = await _chooseProvider(
      context,
      title: 'Link another sign-in',
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
          const Text(
            'All the essentials stay free.',
            style: TextStyle(color: HisaabColors.muted, height: 1.5),
          ),
          const SizedBox(height: 22),
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: HisaabColors.lilac,
              borderRadius: BorderRadius.circular(28),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: _PremiumIllustration()),
                SizedBox(height: 18),
                Text(
                  'Less noise.\nMore good company.',
                  style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 32,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.8,
                    height: 1.15,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'Enjoy Hisaab without ads, wherever you sign in.',
                  style: TextStyle(height: 1.5),
                ),
              ],
            ),
          ),
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
                  : 'Ads are paused while your store purchase is verified. Your scan allowance updates after verification.',
            ),
          ],
          const SizedBox(height: 20),
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: const BorderSide(color: HisaabColors.primary, width: 1.5),
            ),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Yearly',
                    style: TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'For regular bill scanners',
                    style: TextStyle(color: HisaabColors.muted),
                  ),
                  const SizedBox(height: 20),
                  const _PlanBenefit(
                    icon: Icons.block_outlined,
                    title: 'No banner ads',
                  ),
                  const _PlanBenefit(
                    icon: Icons.document_scanner_outlined,
                    title: '100 successful scans / month',
                    subtitle: 'Resets on the first of the month, IST.',
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
                            fontFamily: 'Outfit',
                            fontSize: 36,
                            fontWeight: FontWeight.w600,
                            color: HisaabColors.ink,
                          ),
                          children: const [
                            TextSpan(
                              text: ' / year',
                              style: TextStyle(
                                fontFamily: 'WorkSans',
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
          const _AccountNotice(
            icon: Icons.favorite_border_rounded,
            color: HisaabColors.mint,
            title: 'Everyday sharing stays free',
            body:
                'Manual expense splitting and 5 successful bill scans each month are included on the free plan.',
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
  const _AccountIcon(this.icon, {this.destructive = false});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: destructive ? HisaabColors.peach : HisaabColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(
        icon,
        color: destructive ? clay : HisaabColors.primary,
        size: 23,
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
  const _AccountRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
  });
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    leading: _AccountIcon(icon, destructive: destructive),
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
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
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
  final String? subtitle;
  const _PlanBenefit({required this.icon, required this.title, this.subtitle});
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
              if (subtitle != null) ...[
                const SizedBox(height: 5),
                Text(
                  subtitle!,
                  style: const TextStyle(
                    fontSize: 14,
                    color: HisaabColors.muted,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

class _PremiumIllustration extends StatelessWidget {
  const _PremiumIllustration();
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 148,
    height: 100,
    child: Stack(
      children: [
        Positioned(
          left: 10,
          top: 10,
          child: Transform.rotate(
            angle: -.15,
            child: Container(
              width: 75,
              height: 82,
              decoration: BoxDecoration(
                color: HisaabColors.primary,
                borderRadius: BorderRadius.circular(23),
              ),
              child: const Icon(
                Icons.auto_awesome_rounded,
                color: Colors.white,
                size: 38,
              ),
            ),
          ),
        ),
        Positioned(
          right: 3,
          bottom: 5,
          child: Container(
            width: 61,
            height: 61,
            decoration: BoxDecoration(
              color: HisaabColors.mint,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: HisaabColors.lilac, width: 4),
            ),
            child: const Icon(
              Icons.check_rounded,
              color: HisaabColors.teal,
              size: 32,
            ),
          ),
        ),
        const Positioned(
          top: 0,
          right: 18,
          child: Icon(Icons.add_rounded, color: HisaabColors.teal, size: 20),
        ),
      ],
    ),
  );
}

class _ScanAllowance extends StatefulWidget {
  final AppController controller;
  const _ScanAllowance({required this.controller});
  @override
  State<_ScanAllowance> createState() => _ScanAllowanceState();
}

class _ScanAllowanceState extends State<_ScanAllowance> {
  late final ReceiptCoordinator receipts = widget.controller.receipts;
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await receipts.initialize();
      await receipts.refreshAllowance();
    } catch (_) {
      if (mounted) error = 'Connect to check your current scan allowance.';
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: receipts,
    builder: (context, _) {
      final remaining = receipts.allowance['remaining'];
      final cap = receipts.allowance['cap'];
      if (loading) {
        return const Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Checking your scan allowance…')),
          ],
        );
      }
      if (error != null || remaining is! num || cap is! num || cap <= 0) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              error ?? 'Scan allowance is unavailable.',
              style: const TextStyle(height: 1.5),
            ),
            TextButton.icon(
              onPressed: load,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$remaining of $cap scans left',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (remaining / cap).clamp(0.0, 1.0),
              minHeight: 7,
              color: HisaabColors.primary,
              backgroundColor: Colors.white,
              semanticsLabel: '$remaining of $cap scans remaining',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.controller.demo
                ? 'Local demo allowance'
                : 'Resets on the first of the month, IST.',
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: HisaabColors.muted,
            ),
          ),
        ],
      );
    },
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
          Align(alignment: Alignment.centerLeft, child: _AccountIcon(icon)),
          const SizedBox(height: 18),
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'Outfit',
              fontSize: 26,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: const TextStyle(height: 1.5, color: HisaabColors.muted),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, 'google'),
            child: Text('$action Google'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, 'apple'),
            icon: const Icon(Icons.apple_rounded),
            label: Text('$action Apple'),
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
