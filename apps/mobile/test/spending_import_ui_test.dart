import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show FlutterSecureStorage;
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/controller.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/core/native_services.dart';
import 'package:hisaab/core/spending_import.dart';
import 'package:hisaab/features/spending_import_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestBilling extends BillingService {
  @override
  Future<void> signOut() async {}
}

class _DelayedImports extends SpendingImportService {
  _DelayedImports() : super(android: false);
  Completer<void>? shutdown;
  @override
  Future<void> configureOwner(String? ownerId) async {
    if (ownerId == null) await shutdown?.future;
  }

  @override
  Future<String> pdfText(String path, {String? password}) async =>
      throw PlatformException(code: 'pdf_password', message: 'Password needed');
}

final class _PickedFile extends PlatformFile {
  final File file;
  _PickedFile(this.file);
  @override
  String get name => file.uri.pathSegments.last;
  @override
  Uri get uri => file.uri;
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

class _Picker extends FilePickerPlatform {
  final File file;
  _Picker(this.file);
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _PickedFile(file);
  @override
  Future<void> clearTemporaryFiles() async {}
}

void main() {
  for (final pdf in [false, true]) {
    testWidgets(
      pdf
          ? 'PDF password is hidden immediately during delayed native logout'
          : 'statement review is hidden immediately during delayed native logout',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        final imports = _DelayedImports();
        final controller = AppController(
          spendingImports: imports,
          billing: _TestBilling(),
        );
        await controller.startDemo();
        final directory = Directory.systemTemp.createTempSync(
          'spending-import-',
        );
        final file = File('${directory.path}/statement.${pdf ? 'pdf' : 'csv'}')
          ..writeAsStringSync(
            pdf
                ? '%PDF'
                : 'Date,Description,Amount,Type\n2026-09-29,Private coffee record,120,debit',
          );
        final oldPicker = FilePickerPlatform.instance;
        FilePickerPlatform.instance = _Picker(file);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          controller.dispose();
          FilePickerPlatform.instance = oldPicker;
          directory.deleteSync(recursive: true);
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: HisaabTheme.light,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => openSpendingImport(context, controller),
                  child: const Text('Open importer'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open importer'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.text(pdf ? 'Choose PDF' : 'Choose CSV'),
        );
        // Drive each file-I/O continuation outside the fake clock, then pump
        // its next Flutter continuation. Dialogs keep a spinner animating.
        await tester.tap(find.text(pdf ? 'Choose PDF' : 'Choose CSV'));
        final ready = find.text(
          pdf ? 'Unlock this statement' : 'Private coffee record',
        );
        for (
          var attempt = 0;
          attempt < 80 && ready.evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pump(const Duration(milliseconds: 400));
        if (pdf) {
          expect(find.text('Unlock this statement'), findsOneWidget);
          await tester.enterText(find.byType(TextField), 'private-password');
        } else {
          expect(find.text('Private coffee record'), findsOneWidget);
          expect(find.text('Save 1 transactions'), findsOneWidget);
          await tester.binding.setSurfaceSize(const Size(320, 640));
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.scrollUntilVisible(
            find.text('Private coffee record'),
            200,
            scrollable: find.descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            find.text('Private coffee record').hitTestable(),
            findsOneWidget,
          );
          expect(
            find.text('Save 1 transactions').hitTestable(),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
        imports.shutdown = Completer<void>();
        final logout = controller.logout();
        await tester.pump();
        // Native cleanup is still pending and userId has not yet changed.
        expect(controller.userId, 'demo-you');
        expect(find.text('Session ended'), findsWidgets);
        expect(find.text('Private coffee record'), findsNothing);
        expect(find.text('Save 1 transactions'), findsNothing);
        expect(find.text('Unlock this statement'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        imports.shutdown!.complete();
        for (var attempt = 0; attempt < 30 && controller.signedIn; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(controller.signedIn, isFalse);
        await logout;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
