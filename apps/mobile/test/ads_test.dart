import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/ads.dart';

void main() {
  test('banner allowlist excludes protected money and purchase flows', () {
    bool allows(
      String route, {
      bool premium = false,
      bool protected = false,
      bool demo = false,
      bool consent = true,
      bool online = true,
    }) => AdPolicy.allows(
      route: route,
      configured: true,
      consent: consent,
      adFree: premium,
      protectedFlow: protected,
      demo: demo,
      online: online,
    );
    for (final route in ['home', 'groups', 'activity']) {
      expect(allows(route), isTrue);
    }
    for (final route in [
      'auth',
      'expense',
      'settlement',
      'premium',
      'settings',
      'detail',
    ]) {
      expect(allows(route), isFalse);
    }
    expect(allows('home', premium: true), isFalse);
    expect(allows('home', protected: true), isFalse);
    expect(allows('home', demo: true), isFalse);
    expect(allows('home', consent: false), isFalse);
    expect(allows('home', online: false), isFalse);
  });
}
