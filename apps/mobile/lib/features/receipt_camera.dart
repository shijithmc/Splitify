import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/design.dart';
import '../core/receipt_images.dart';
import '../main.dart';

class ReceiptCameraPage extends StatefulWidget {
  const ReceiptCameraPage({super.key});
  @override
  State<ReceiptCameraPage> createState() => _ReceiptCameraPageState();
}

class _ReceiptCameraPageState extends State<ReceiptCameraPage>
    with WidgetsBindingObserver {
  CameraController? camera;
  String? error;
  bool taking = false, initializing = false;
  List<double>? bounds;
  DateTime lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initialize();
  }

  Future<void> initialize() async {
    if (initializing || !mounted) return;
    initializing = true;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw const FormatException(
          'No camera found. Choose a bill from your gallery.',
        );
      }
      final description =
          cameras
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .firstOrNull ??
          cameras.first;
      final next = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      await next.initialize();
      if (!mounted) {
        await next.dispose();
        return;
      }
      camera = next;
      await next.startImageStream(frame);
      if (mounted) setState(() => error = null);
    } catch (failure) {
      if (mounted) {
        setState(
          () => error =
              failure is CameraException && failure.code.contains('Access')
              ? 'Camera access is off. Enable it in Settings, or choose a photo from your gallery.'
              : 'The camera is unavailable. Choose from your gallery instead.',
        );
      }
    } finally {
      initializing = false;
    }
  }

  void frame(CameraImage image) {
    if (!mounted ||
        taking ||
        DateTime.now().difference(lastFrame).inMilliseconds < 350) {
      return;
    }
    lastFrame = DateTime.now();
    final plane = image.planes.first;
    Uint8List bytes = plane.bytes;
    var width = image.width, height = image.height;
    var stride = plane.bytesPerRow, pixels = plane.bytesPerPixel ?? 1;
    if (image.format.group == ImageFormatGroup.bgra8888) {
      final step = math.max(1, math.max(width, height) ~/ 240);
      width = image.width ~/ step;
      height = image.height ~/ step;
      bytes = Uint8List(width * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final i = y * step * plane.bytesPerRow + x * step * 4;
          bytes[y * width + x] =
              (plane.bytes[i] * .114 +
                      plane.bytes[i + 1] * .587 +
                      plane.bytes[i + 2] * .299)
                  .round();
        }
      }
      stride = width;
      pixels = 1;
    }
    var found = detectReceiptBounds(bytes, width, height, stride, pixels);
    if (found != null && Platform.isAndroid) {
      final rotation = camera?.description.sensorOrientation;
      if (rotation == 90) {
        found = [1 - found[3], found[0], 1 - found[1], found[2]];
      }
      if (rotation == 270) {
        found = [found[1], 1 - found[2], found[3], 1 - found[0]];
      }
    }
    if (mounted) setState(() => bounds = found);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final old = camera;
      camera = null;
      old?.dispose();
    }
    if (state == AppLifecycleState.resumed && !taking) initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    camera?.dispose();
    super.dispose();
  }

  Future<void> capture() async {
    final current = camera;
    if (current == null || taking) return;
    setState(() => taking = true);
    String? temporary;
    var accepted = false;
    try {
      await current.stopImageStream();
      final file = await current.takePicture();
      temporary = file.path;
      await SystemSound.play(SystemSoundType.click);
      final bytes = await compute(normalizeReceiptImage, {
        'bytes': await file.readAsBytes(),
      });
      if (!mounted) return;
      final chosen = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(builder: (_) => ReceiptCropPage(bytes: bytes)),
      );
      if (chosen != null && mounted) {
        accepted = true;
        Navigator.pop(context, chosen);
        return;
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not capture this bill. Flatten it, avoid glare, and try again.',
        );
      }
    } finally {
      if (temporary != null) {
        try {
          await File(temporary).delete();
        } catch (_) {}
      }
      if (mounted && !accepted) {
        setState(() => taking = false);
        if (camera == null) {
          await initialize();
        } else if (camera?.value.isInitialized == true) {
          try {
            await camera!.startImageStream(frame);
          } catch (_) {}
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: HisaabColors.ink,
    appBar: AppBar(
      title: const Text('Photograph your bill'),
      backgroundColor: HisaabColors.ink,
      foregroundColor: Colors.white,
      titleTextStyle: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(color: Colors.white),
    ),
    body: SafeArea(
      child: _ReceiptImageLayout(
        guidance: Container(
          margin: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            children: [
              Icon(Icons.document_scanner_outlined, color: Colors.white),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Flatten the bill · Avoid glare · Keep every edge in frame',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        preview: error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.no_photography_outlined,
                          size: 48,
                          color: Colors.white70,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            : camera?.value.isInitialized != true
            ? const Center(
                child: CircularProgressIndicator(color: Colors.white),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(28),
                  child: ColoredBox(
                    color: HisaabColors.ink,
                    child: Center(
                      child: CameraPreview(
                        camera!,
                        child: CustomPaint(
                          painter: _ReceiptEdgePainter(bounds),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        controls: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                bounds == null
                    ? 'Move the bill onto a contrasting surface.'
                    : 'Edges found. Check the crop after taking the photo.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.white70),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: HisaabColors.ink,
                  disabledBackgroundColor: Colors.white24,
                  disabledForegroundColor: Colors.white54,
                ),
                onPressed: taking || camera?.value.isInitialized != true
                    ? null
                    : capture,
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(taking ? 'Preparing photo…' : 'Take photo'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context, 'gallery'),
                child: const Text('Choose from gallery instead'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReceiptEdgePainter extends CustomPainter {
  final List<double>? bounds;
  _ReceiptEdgePainter(this.bounds);
  @override
  void paint(Canvas canvas, Size size) {
    final b = bounds;
    if (b == null) return;
    canvas.drawRect(
      Rect.fromLTRB(
        b[0] * size.width,
        b[1] * size.height,
        b[2] * size.width,
        b[3] * size.height,
      ),
      Paint()
        ..color = const Color(0xFFBBE681)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(covariant _ReceiptEdgePainter oldDelegate) =>
      !listEquals(bounds, oldDelegate.bounds);
}

class ReceiptCropPage extends StatefulWidget {
  final Uint8List bytes;
  const ReceiptCropPage({super.key, required this.bytes});
  @override
  State<ReceiptCropPage> createState() => _ReceiptCropPageState();
}

class _ReceiptCropPageState extends State<ReceiptCropPage> {
  List<double>? bounds;
  Uint8List? cropped;
  bool crop = true, preparing = true;
  @override
  void initState() {
    super.initState();
    prepare();
  }

  Future<void> prepare() async {
    final found = await compute(receiptImageBounds, widget.bytes);
    final result = found == null
        ? widget.bytes
        : await compute(normalizeReceiptImage, {
            'bytes': widget.bytes,
            'crop': found,
          });
    if (mounted) {
      setState(() {
        bounds = found;
        cropped = result;
        preparing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Keep this photo?')),
    body: SafeArea(
      child: _ReceiptImageLayout(
        guidance: Container(
          margin: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: HisaabColors.mint,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Row(
            children: [
              Icon(Icons.zoom_in_rounded, color: HisaabColors.positive),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Pinch to check the details. Make sure every item and the total are readable.',
                ),
              ),
            ],
          ),
        ),
        preview: preparing
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: ColoredBox(
                    color: HisaabColors.line,
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: Center(
                        child: Image.memory(
                          crop ? cropped! : widget.bytes,
                          gaplessPlayback: true,
                          semanticLabel: crop
                              ? 'Cropped bill, pinch to zoom'
                              : 'Full bill photo, pinch to zoom',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        controls: Column(
          children: [
            if (bounds != null)
              SwitchListTile(
                title: const Text('Use detected crop'),
                subtitle: const Text('Turn off to keep the full photo'),
                value: crop,
                onChanged: (v) => setState(() => crop = v),
              ),
            if (bounds == null && !preparing)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Edges were unclear. The full photo is kept.',
                  style: TextStyle(color: clay),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Retake / choose again'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: preparing
                          ? null
                          : () => Navigator.pop(
                              context,
                              crop ? cropped : widget.bytes,
                            ),
                      child: const Text('Use photo'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Keep the image usable while allowing large text and controls to scroll.
class _ReceiptImageLayout extends StatelessWidget {
  final Widget guidance, preview, controls;
  const _ReceiptImageLayout({
    required this.guidance,
    required this.preview,
    required this.controls,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scrollable =
          constraints.maxHeight < 600 ||
          MediaQuery.textScalerOf(context).scale(16) > 20;
      final content = Column(
        children: [
          guidance,
          if (scrollable)
            SizedBox(
              height: (constraints.maxHeight * .5).clamp(180.0, 420.0),
              child: preview,
            )
          else
            Expanded(child: preview),
          controls,
        ],
      );
      return scrollable ? SingleChildScrollView(child: content) : content;
    },
  );
}
