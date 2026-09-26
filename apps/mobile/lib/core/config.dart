import 'dart:io';
import 'package:flutter/foundation.dart';

class AppConfig {
  static const inviteHost = String.fromEnvironment('INVITE_HOST');
  static const apiUrl = String.fromEnvironment('API_BASE_URL');
  static const googleClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const googleServerId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );
  static const appleClientId = String.fromEnvironment('APPLE_SERVICE_ID');
  static const appleRedirect = String.fromEnvironment('APPLE_REDIRECT_URI');
  static const privacyUrl = String.fromEnvironment('PRIVACY_URL');
  static const termsUrl = String.fromEnvironment('TERMS_URL');
  static const pushEnabled = bool.fromEnvironment('PUSH_ENABLED');
  static const adsEnabled = bool.fromEnvironment('ADS_ENABLED');
  static const demoEnabled =
      !kReleaseMode || bool.fromEnvironment('ENABLE_DEMO');
  static String get revenueCatKey => Platform.isIOS
      ? const String.fromEnvironment('REVENUECAT_IOS_KEY')
      : const String.fromEnvironment('REVENUECAT_ANDROID_KEY');
  static String get bannerId => Platform.isIOS
      ? const String.fromEnvironment('ADMOB_IOS_BANNER_ID')
      : const String.fromEnvironment('ADMOB_ANDROID_BANNER_ID');
  static bool get configured =>
      apiUrl.isNotEmpty &&
      (Uri.tryParse(apiUrl)?.scheme == 'https' ||
          (!kReleaseMode && Uri.tryParse(apiUrl)?.scheme == 'http'));
  static String get subscriptionUrl => Platform.isIOS
      ? 'https://apps.apple.com/account/subscriptions'
      : 'https://play.google.com/store/account/subscriptions';
}
