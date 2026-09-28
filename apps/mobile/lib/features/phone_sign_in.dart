import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/design.dart';
import '../core/models.dart';
import '../core/phone_auth.dart';

class PhoneSignInPage extends StatefulWidget {
  final PhoneAuthService service;
  const PhoneSignInPage({super.key, required this.service});

  @override
  State<PhoneSignInPage> createState() => _PhoneSignInPageState();
}

class _PhoneSignInPageState extends State<PhoneSignInPage> {
  final _phone = TextEditingController(text: '+91 ');
  final _name = TextEditingController();
  final _code = TextEditingController();
  PhoneChallenge? _challenge;
  String? _sentTo, _error;
  DateTime? _resendAt;
  Timer? _timer;
  bool _busy = false;
  int get _remaining => _resendAt == null
      ? 0
      : (_resendAt!.difference(DateTime.now()).inMilliseconds / 1000)
            .ceil()
            .clamp(0, 3600);

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || _remaining > 0) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final phone = PhoneAuthService.normalizePhone(_phone.text);
      final challenge = await widget.service.sendCode(phone);
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _sentTo = phone;
        _code.clear();
        _resendAt = DateTime.now().add(
          Duration(seconds: challenge.resendAfterSeconds),
        );
      });
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || _remaining == 0) timer.cancel();
        if (mounted) setState(() {});
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_busy || _challenge == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.service.verify(
        _challenge!,
        _code.text.trim(),
        name: _name.text,
      );
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object error) => error is ApiFailure
      ? '$error'
      : 'Phone verification could not finish. Please try again.';

  @override
  Widget build(BuildContext context) {
    final enteringCode = _challenge != null;
    final purpose = widget.service.purpose;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Phone verification')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Icon(
                      Icons.sms_outlined,
                      size: 42,
                      color: HisaabColors.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    enteringCode
                        ? 'Check your messages'
                        : switch (purpose) {
                            PhoneAuthPurpose.signIn =>
                              'Sign in with your phone',
                            PhoneAuthPurpose.link => 'Link your phone number',
                            PhoneAuthPurpose.reauthenticate =>
                              'Confirm your account',
                          },
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    enteringCode
                        ? 'Enter the 6-digit code sent to $_sentTo.'
                        : purpose == PhoneAuthPurpose.reauthenticate
                        ? 'Use a phone number already linked to this account.'
                        : 'We’ll send you a one-time code by SMS. Include your country code.',
                    style: const TextStyle(
                      height: 1.5,
                      color: HisaabColors.muted,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (!enteringCode) ...[
                    TextField(
                      key: const Key('phone-number'),
                      controller: _phone,
                      enabled: !_busy,
                      keyboardType: TextInputType.phone,
                      autofillHints: const [AutofillHints.telephoneNumber],
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                        hintText: '+91 98765 43210',
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                    if (purpose == PhoneAuthPurpose.signIn) ...[
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('phone-display-name'),
                        controller: _name,
                        enabled: !_busy,
                        maxLength: 100,
                        textCapitalization: TextCapitalization.words,
                        autofillHints: const [AutofillHints.name],
                        decoration: const InputDecoration(
                          labelText: 'Your name (optional)',
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Already use Google or Apple? Sign in that way, then link your phone in Settings to keep the same account.',
                        style: TextStyle(
                          height: 1.5,
                          color: HisaabColors.muted,
                        ),
                      ),
                    ],
                  ] else ...[
                    TextField(
                      key: const Key('phone-code'),
                      controller: _code,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      maxLength: 6,
                      decoration: const InputDecoration(
                        labelText: 'Verification code',
                      ),
                      onSubmitted: (_) => _verify(),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: const TextStyle(color: HisaabColors.warning),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy || (!enteringCode && _remaining > 0)
                        ? null
                        : enteringCode
                        ? _verify
                        : _send,
                    child: Text(
                      _busy
                          ? 'Please wait…'
                          : enteringCode
                          ? purpose == PhoneAuthPurpose.signIn
                                ? 'Verify and sign in'
                                : 'Verify phone number'
                          : _remaining > 0
                          ? 'Send code in ${_remaining}s'
                          : 'Send code',
                    ),
                  ),
                  if (enteringCode) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _busy || _remaining > 0 ? null : _send,
                      child: Text(
                        _remaining > 0
                            ? 'Resend code in ${_remaining}s'
                            : 'Resend code',
                      ),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _challenge = null;
                              _sentTo = null;
                              _code.clear();
                              _error = null;
                            }),
                      child: const Text('Change phone number'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
