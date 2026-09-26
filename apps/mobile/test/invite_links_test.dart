import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/invite_links.dart';

void main() {
  final token = 'a' * 64;
  test('only owned invitation links yield tokens', () {
    expect(invitationToken(Uri.parse('hisaab://invite/$token')), token);
    expect(invitationToken(Uri.parse('hisaab://invite?token=$token')), token);
    expect(
      invitationToken(
        Uri.parse('https://split.example/invite/$token'),
        httpsHost: 'split.example',
      ),
      token,
    );
    expect(
      invitationToken(
        Uri.parse('https://wrong.example/invite/$token'),
        httpsHost: 'split.example',
      ),
      isNull,
    );
    expect(
      invitationToken(
        Uri.parse('http://split.example/invite/$token'),
        httpsHost: 'split.example',
      ),
      isNull,
    );
    expect(invitationToken(Uri.parse('hisaab://auth/$token')), isNull);
    expect(invitationToken(Uri.parse('hisaab://invite/short')), isNull);
    expect(
      invitationToken(
        Uri.parse('https://split.example/sign-in/$token'),
        httpsHost: 'split.example',
      ),
      isNull,
    );
  });
}
