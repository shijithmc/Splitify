import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  // No native inbox exists in widget/unit tests. Individual import tests install
  // their own channel handler to exercise consent, owner changes and responses.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app.hisaab/spending'), (
        call,
      ) async {
        if (call.method == 'smsEnabled') return false;
        if (call.method == 'importSms') return {'transactions': <Object>[]};
        return null;
      });
  await testMain();
}
