import 'models.dart';
import 'repository.dart';

enum PhoneAuthPurpose { signIn, link, reauthenticate }

class PhoneChallenge {
  final String nonce;
  final DateTime expiresAt;
  final int resendAfterSeconds;
  const PhoneChallenge(this.nonce, this.expiresAt, this.resendAfterSeconds);
}

/// Phone proofs stay in memory and are bound to the account that opened them.
class PhoneAuthService {
  final ApiRepository repository;
  final PhoneAuthPurpose purpose;
  final bool Function() isCurrent;
  final int _generation;
  final String? _account;

  PhoneAuthService(
    this.repository, {
    this.purpose = PhoneAuthPurpose.signIn,
    required this.isCurrent,
  }) : _generation = repository.sessionGeneration,
       _account = repository.session?['user']?['id'];

  static String normalizePhone(String input) {
    final phone = input.trim().replaceAll(RegExp(r'[\s()\-]'), '');
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone)) {
      throw ApiFailure(
        'Enter your phone number with country code, such as +91.',
      );
    }
    return phone;
  }

  void _requireCurrent() {
    if (!isCurrent() ||
        repository.sessionGeneration != _generation ||
        repository.session?['user']?['id'] != _account ||
        (purpose != PhoneAuthPurpose.signIn && _account == null)) {
      throw ApiFailure('Account changed. Start phone verification again.');
    }
  }

  Future<PhoneChallenge> sendCode(String input) async {
    _requireCurrent();
    final phone = normalizePhone(input);
    final path = switch (purpose) {
      PhoneAuthPurpose.signIn => '/auth/phone/challenge',
      PhoneAuthPurpose.link => '/auth/phone/link/challenge',
      PhoneAuthPurpose.reauthenticate => '/auth/phone/reauthenticate/challenge',
    };
    final result = await repository.request('POST', path, {
      'phoneNumber': phone,
    });
    _requireCurrent();
    return PhoneChallenge(
      result['nonce'] as String,
      DateTime.parse(result['expiresAt'] as String),
      (result['resendAfterSeconds'] as num).toInt(),
    );
  }

  Future<Json> verify(
    PhoneChallenge challenge,
    String code, {
    String? name,
  }) async {
    _requireCurrent();
    if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
      throw ApiFailure('Enter the 6-digit code from your SMS.');
    }
    if (!challenge.expiresAt.isAfter(DateTime.now())) {
      throw ApiFailure('This code expired. Request a new code.');
    }
    final reauth = purpose == PhoneAuthPurpose.reauthenticate;
    final result = await repository.request(
      'POST',
      switch (purpose) {
        PhoneAuthPurpose.signIn => '/auth/sign-in',
        PhoneAuthPurpose.link => '/auth/link',
        PhoneAuthPurpose.reauthenticate => '/auth/phone/reauthenticate',
      },
      reauth
          ? {'nonce': challenge.nonce, 'code': code}
          : {
              'provider': 'phone',
              'nonce': challenge.nonce,
              'idToken': code,
              if (name?.trim().isNotEmpty == true) 'displayName': name!.trim(),
            },
    );
    _requireCurrent();
    if (reauth) {
      if (result['user']?['id'] != _account) {
        throw ApiFailure('Use a phone number linked to your current account.');
      }
      await repository.saveSession(result);
    }
    return result;
  }
}
