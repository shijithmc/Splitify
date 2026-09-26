import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'models.dart';

const receiptNative = MethodChannel('app.hisaab/receipts');

List<double>? receiptImageBounds(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final small = img.copyResize(decoded, width: 240);
  final luminance = Uint8List(small.width * small.height);
  for (final pixel in small) {
    luminance[pixel.y * small.width + pixel.x] =
        (pixel.r * .299 + pixel.g * .587 + pixel.b * .114).round();
  }
  return detectReceiptBounds(
    luminance,
    small.width,
    small.height,
    small.width,
    1,
  );
}

/// Bounded, bundled document-edge estimate; no downloaded ML model required.
/// A low-contrast frame returns null so the user retains the complete image.
List<double>? detectReceiptBounds(
  Uint8List luma,
  int width,
  int height,
  int rowStride,
  int pixelStride,
) {
  if (width < 24 ||
      height < 24 ||
      luma.length < rowStride * (height - 1) + width * pixelStride) {
    return null;
  }
  final step = math.max(1, math.max(width, height) ~/ 160);
  final edges = <(int, int)>[];
  for (var y = step * 2; y < height - step * 2; y += step) {
    for (var x = step * 2; x < width - step * 2; x += step) {
      final i = y * rowStride + x * pixelStride;
      final dx = (luma[i + step * pixelStride] - luma[i - step * pixelStride])
          .abs();
      final dy = (luma[i + step * rowStride] - luma[i - step * rowStride])
          .abs();
      if (dx + dy > 100) edges.add((x, y));
    }
  }
  if (edges.length < 40) return null;
  final xs = edges.map((p) => p.$1).toList()..sort();
  final ys = edges.map((p) => p.$2).toList()..sort();
  final trim = (edges.length * .015).floor();
  final left = (xs[trim] / width - .035).clamp(0.0, 1.0);
  final top = (ys[trim] / height - .035).clamp(0.0, 1.0);
  final right = (xs[xs.length - 1 - trim] / width + .035).clamp(0.0, 1.0);
  final bottom = (ys[ys.length - 1 - trim] / height + .035).clamp(0.0, 1.0);
  if ((right - left) * (bottom - top) < .18 ||
      right - left < .25 ||
      bottom - top < .3) {
    return null;
  }
  return [left, top, right, bottom];
}

/// Decode, orient, resize, copy only pixels, and encode. Copying into a fresh
/// image deliberately drops EXIF, GPS, XMP and PNG text chunks.
Uint8List normalizeReceiptImage(Json input) {
  final bytes = input['bytes'] as Uint8List;
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 60000000) {
    throw const FormatException(
      'Choose a readable image no larger than 60 megapixels.',
    );
  }
  var source = img.bakeOrientation(decoder!.decodeFrame(0)!);
  final crop = (input['crop'] as List?)?.cast<double>();
  if (crop != null) {
    final x = (crop[0] * source.width).round().clamp(0, source.width - 1);
    final y = (crop[1] * source.height).round().clamp(0, source.height - 1);
    source = img.copyCrop(
      source,
      x: x,
      y: y,
      width: ((crop[2] - crop[0]) * source.width).round().clamp(
        1,
        source.width - x,
      ),
      height: ((crop[3] - crop[1]) * source.height).round().clamp(
        1,
        source.height - y,
      ),
    );
  }
  if (math.max(source.width, source.height) > 2048) {
    source = img.copyResize(
      source,
      width: source.width >= source.height ? 2048 : null,
      height: source.height > source.width ? 2048 : null,
      interpolation: img.Interpolation.average,
    );
  }
  final clean = img.Image(
    width: source.width,
    height: source.height,
    numChannels: 3,
  );
  img.fill(clean, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(clean, source);
  final encoded = Uint8List.fromList(img.encodeJpg(clean, quality: 88));
  if (encoded.length > 10 * 1024 * 1024) {
    throw const FormatException(
      'Image is over 10 MB after compression. Crop it or choose a smaller photo.',
    );
  }
  return encoded;
}

Future<List<Uint8List>> importReceiptFile(String path) async {
  final file = File(path);
  if (await file.length() > 60 * 1024 * 1024) {
    throw ApiFailure('Choose a file smaller than 60 MB.');
  }
  final extension = path.toLowerCase().split('.').last;
  if (extension == 'pdf' || extension == 'heic' || extension == 'heif') {
    final values = await receiptNative.invokeListMethod<Uint8List>(
      'rasterize',
      {'path': path, 'pdf': extension == 'pdf'},
    );
    if (values == null || values.isEmpty) {
      throw ApiFailure(
        'This file could not be read. Choose JPEG, PNG, HEIC, or PDF.',
      );
    }
    return [
      for (final bytes in values.take(3))
        await compute(normalizeReceiptImage, {'bytes': bytes}),
    ];
  }
  return [
    await compute(normalizeReceiptImage, {'bytes': await file.readAsBytes()}),
  ];
}
