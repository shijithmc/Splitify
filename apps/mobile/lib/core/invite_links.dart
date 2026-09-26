import 'dart:async';
import 'package:app_links/app_links.dart';
import 'config.dart';

String? invitationToken(Uri uri, {String httpsHost = AppConfig.inviteHost}) {
  final custom = uri.scheme == 'hisaab' && uri.host == 'invite';
  final https =
      uri.scheme == 'https' &&
      httpsHost.isNotEmpty &&
      uri.host == httpsHost &&
      ['invite', 'invites'].contains(uri.pathSegments.firstOrNull);
  if (!custom && !https) return null;
  final segments = uri.pathSegments;
  final token =
      uri.queryParameters['token'] ??
      (custom
          ? segments.firstOrNull
          : segments.length == 2
          ? segments.last
          : null);
  return token != null && RegExp(r'^[A-Za-z0-9_-]{16,512}$').hasMatch(token)
      ? token
      : null;
}

class InviteLinkService {
  StreamSubscription<Uri>? _subscription;
  Future<void> start(Future<void> Function(String) receive) async {
    final links = AppLinks();
    final initial = await links.getInitialLink();
    if (initial != null) {
      final token = invitationToken(initial);
      if (token != null) await receive(token);
    }
    _subscription = links.uriLinkStream.listen((uri) {
      final token = invitationToken(uri);
      if (token != null) unawaited(receive(token));
    });
  }

  Future<void> dispose() async => _subscription?.cancel();
}
