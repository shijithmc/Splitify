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
  final _scroll = ScrollController();
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
    _scroll.dispose();
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
      _showError(error);
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
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    setState(() => _error = _message(error));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
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
          top: false,
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  controller: _scroll,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                  child: AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerRight,
                          child: _VerificationArtwork(
                            enteringCode: enteringCode,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          enteringCode
                              ? 'Check your messages'
                              : switch (purpose) {
                                  PhoneAuthPurpose.signIn =>
                                    'Your number, please',
                                  PhoneAuthPurpose.link =>
                                    'Link your phone number',
                                  PhoneAuthPurpose.reauthenticate =>
                                    'Confirm your account',
                                },
                          style: Theme.of(context).textTheme.headlineLarge,
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
                        const SizedBox(height: 28),
                        if (!enteringCode) ...[
                          TextField(
                            key: const Key('phone-number'),
                            controller: _phone,
                            enabled: !_busy,
                            keyboardType: TextInputType.phone,
                            textInputAction: purpose == PhoneAuthPurpose.signIn
                                ? TextInputAction.next
                                : TextInputAction.done,
                            autofillHints: const [
                              AutofillHints.telephoneNumber,
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Phone number',
                              hintText: '+91 98765 43210',
                              prefixIcon: Icon(Icons.phone_iphone_rounded),
                            ),
                            onSubmitted: purpose == PhoneAuthPurpose.signIn
                                ? null
                                : (_) => _send(),
                          ),
                          if (purpose == PhoneAuthPurpose.signIn) ...[
                            const SizedBox(height: 18),
                            TextField(
                              key: const Key('phone-display-name'),
                              controller: _name,
                              enabled: !_busy,
                              maxLength: 100,
                              textInputAction: TextInputAction.done,
                              textCapitalization: TextCapitalization.words,
                              autofillHints: const [AutofillHints.name],
                              decoration: const InputDecoration(
                                labelText: 'Your name (optional)',
                              ),
                              onSubmitted: (_) => _send(),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: HisaabColors.lilac,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: const Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  ExcludeSemantics(
                                    child: Icon(
                                      Icons.lightbulb_outline_rounded,
                                      color: HisaabColors.primary,
                                    ),
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Already use Google or Apple? Sign in that way, then link your phone in Account to keep the same account.',
                                      style: TextStyle(
                                        height: 1.5,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ] else ...[
                          TextField(
                            key: const Key('phone-code'),
                            controller: _code,
                            enabled: !_busy,
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.done,
                            autofillHints: const [AutofillHints.oneTimeCode],
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            maxLength: 6,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 8,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Verification code',
                              hintText: '000000',
                              counterText: '',
                            ),
                            onSubmitted: (_) => _verify(),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            spacing: 8,
                            children: [
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
                              TextButton(
                                onPressed: _busy || _remaining > 0
                                    ? null
                                    : _send,
                                child: Text(
                                  _remaining > 0
                                      ? 'Resend code in ${_remaining}s'
                                      : 'Resend code',
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Semantics(
                            liveRegion: true,
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: HisaabColors.peach,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: HisaabColors.warning,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
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
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VerificationArtwork extends StatelessWidget {
  final bool enteringCode;
  const _VerificationArtwork({required this.enteringCode});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 120,
      height: 100,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            bottom: 6,
            right: 8,
            child: Transform.rotate(
              angle: -.35,
              child: Container(
                width: 88,
                height: 64,
                decoration: BoxDecoration(
                  color: HisaabColors.mint,
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
            ),
          ),
          Transform.rotate(
            angle: enteringCode ? .12 : .15,
            child: Icon(
              enteringCode
                  ? Icons.mark_email_unread_rounded
                  : Icons.phone_iphone_rounded,
              size: 70,
              color: HisaabColors.primary,
            ),
          ),
          if (!enteringCode)
            const Positioned(
              top: 37,
              left: 47,
              child: Icon(
                Icons.sentiment_satisfied_rounded,
                size: 24,
                color: HisaabColors.primary,
              ),
            ),
          const Positioned(
            top: 0,
            right: 4,
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 23,
              color: Color(0xFFE9A637),
            ),
          ),
          const Positioned(
            left: 8,
            top: 21,
            child: Icon(Icons.circle, size: 8, color: Color(0xFFE9A637)),
          ),
        ],
      ),
    ),
  );
}
