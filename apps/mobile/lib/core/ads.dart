import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'config.dart';
import 'controller.dart';

class AdPolicy {
  static const allowedRoutes = {'home', 'groups', 'activity'};
  static bool allows({
    required String route,
    required bool configured,
    required bool consent,
    required bool adFree,
    required bool protectedFlow,
    required bool demo,
    required bool online,
  }) =>
      configured &&
      consent &&
      !adFree &&
      !protectedFlow &&
      !demo &&
      online &&
      allowedRoutes.contains(route);
}

class SafeBanner extends StatefulWidget {
  final AppController controller;
  final String route;
  const SafeBanner({super.key, required this.controller, required this.route});
  @override
  State<SafeBanner> createState() => _SafeBannerState();
}

class _SafeBannerState extends State<SafeBanner> {
  BannerAd? _ad;
  bool _loaded = false, _consent = false, _starting = false, _sdkReady = false;
  bool get _configured =>
      widget.controller.entitlement.containsKey('adFree') &&
      AppConfig.adsEnabled &&
      const bool.fromEnvironment('ADS_POLICY_REVIEWED') &&
      AppConfig.bannerId.isNotEmpty;
  bool get _allow => AdPolicy.allows(
    route: widget.route,
    configured: _configured && _sdkReady,
    consent: _consent,
    adFree: widget.controller.adFree,
    protectedFlow: widget.controller.protectedDepth > 0,
    demo: widget.controller.demo,
    online: !widget.controller.offline,
  );
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_policyChanged);
    _consentAndLoad();
  }

  Future<void> _consentAndLoad() async {
    if (!_configured ||
        widget.controller.demo ||
        widget.controller.adFree ||
        _starting) {
      return;
    }
    _starting = true;
    try {
      final complete = Completer<void>();
      ConsentInformation.instance.requestConsentInfoUpdate(
        ConsentRequestParameters(tagForUnderAgeOfConsent: true),
        () async {
          try {
            await ConsentForm.loadAndShowConsentFormIfRequired((_) {});
            if (!complete.isCompleted) complete.complete();
          } catch (error, stack) {
            if (!complete.isCompleted) complete.completeError(error, stack);
          }
        },
        (_) {
          if (!complete.isCompleted) complete.complete();
        },
      );
      await complete.future;
      _consent = await ConsentInformation.instance.canRequestAds();
      if (!mounted || !_consent) return;
      // Complete policy setup even when a protected route is currently open.
      // Route eligibility controls loading; it must never bypass SDK setup.
      await MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(
          maxAdContentRating: MaxAdContentRating.g,
          ageRestrictedTreatment: AgeRestrictedTreatment.child,
        ),
      );
      if (!mounted) return;
      await MobileAds.instance.initialize();
      if (!mounted) return;
      _sdkReady = true;
      _policyChanged();
    } catch (_) {
      _sdkReady = false;
      _consent = false;
      if (mounted) _policyChanged();
    } finally {
      _starting = false;
    }
  }

  void _policyChanged() {
    if (!_allow) {
      _ad?.dispose();
      _ad = null;
      _loaded = false;
      if (mounted) setState(() {});
      return;
    }
    if (_ad != null) return;
    _ad = BannerAd(
      size: AdSize.banner,
      adUnitId: AppConfig.bannerId,
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (mounted && _allow) {
            setState(() => _loaded = true);
          } else {
            ad.dispose();
          }
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          _ad = null;
          _loaded = false;
          if (mounted) setState(() {});
        },
      ),
      request: const AdRequest(nonPersonalizedAds: true),
    );
    _ad!.load();
  }

  @override
  void didUpdateWidget(covariant SafeBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _policyChanged();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_policyChanged);
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !_allow || !_loaded || _ad == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            children: [
              Text(
                'Advertisement',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              SizedBox(
                width: _ad!.size.width.toDouble(),
                height: _ad!.size.height.toDouble(),
                child: AdWidget(ad: _ad!),
              ),
            ],
          ),
        );
}
