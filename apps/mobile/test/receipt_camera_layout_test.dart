import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hisaab/core/design.dart';
import 'package:hisaab/features/receipt_camera.dart';
import 'package:image/image.dart' as img;

Future<void> compactDisplayWithFonts(WidgetTester tester) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.runAsync(() async {
    for (final name in ['Outfit', 'WorkSans']) {
      await (FontLoader(
        name,
      )..addFont(rootBundle.load('assets/fonts/$name-Regular.ttf'))).load();
    }
  });
}

void main() {
  testWidgets('camera gallery fallback stays reachable with 200% text', (
    tester,
  ) async {
    await compactDisplayWithFonts(tester);
    const channel = MethodChannel('plugins.flutter.io/camera');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => []);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Object? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await Navigator.push<Object>(
                  context,
                  MaterialPageRoute(builder: (_) => const ReceiptCameraPage()),
                );
              },
              child: const Text('Open camera'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open camera'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Take photo'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Take photo'))
          .onPressed,
      isNull,
    );
    await tester.scrollUntilVisible(
      find.text('Choose from gallery instead'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Choose from gallery instead'));
    await tester.pumpAndSettle();
    expect(result, 'gallery');
    expect(find.text('Open camera'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('crop confirmation keeps photo and controls at 200% text', (
    tester,
  ) async {
    await compactDisplayWithFonts(tester);
    final pixels = img.Image(width: 40, height: 80);
    img.fill(pixels, color: img.ColorRgb8(255, 255, 255));
    final original = Uint8List.fromList(img.encodePng(pixels));
    Uint8List? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: HisaabTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                result = await Navigator.push<Uint8List>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ReceiptCropPage(bytes: original),
                  ),
                );
              },
              child: const Text('Review photo'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review photo'));
    await tester.pump();
    // Cropping uses a real isolate. Let it finish outside the fake clock.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      if (tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Use photo'),
              )
              .onPressed !=
          null) {
        break;
      }
    }
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Use photo'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Use photo'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Use photo'));
    await tester.pumpAndSettle();
    expect(result, orderedEquals(original));
    expect(find.text('Review photo'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
