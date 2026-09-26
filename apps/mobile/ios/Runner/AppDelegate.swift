import Flutter
import UIKit
import PDFKit
import ImageIO

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ReceiptNative") {
      ReceiptNative.register(with: registrar)
    }
  }
}

final class ReceiptNative: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "app.hisaab/receipts", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ReceiptNative(), channel: channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "protectDraftDirectory", let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String {
      do {
        var directory = URL(fileURLWithPath: path, isDirectory: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
        result(nil)
      } catch { result(FlutterError(code: "draft_protection_failed", message: "Could not protect the receipt draft directory.", details: nil)) }
      return
    }
    guard call.method == "rasterize", let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String else {
      result(FlutterMethodNotImplemented); return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let file = URL(fileURLWithPath: path)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 60 * 1024 * 1024 else { throw ReceiptError.invalid }
        var images = [FlutterStandardTypedData]()
        if arguments["pdf"] as? Bool == true {
          guard let pdf = PDFDocument(url: file), !pdf.isLocked else { throw ReceiptError.invalid }
          for index in 0..<min(3, pdf.pageCount) {
            guard let page = pdf.page(at: index) else { throw ReceiptError.invalid }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw ReceiptError.invalid }
            let scale = 2048 / max(bounds.width, bounds.height)
            let output = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: output, format: format).image { context in
              UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: output))
              context.cgContext.translateBy(x: 0, y: output.height)
              context.cgContext.scaleBy(x: scale, y: -scale)
              page.draw(with: .mediaBox, to: context.cgContext)
            }
            guard let bytes = image.jpegData(compressionQuality: 0.88) else { throw ReceiptError.invalid }
            images.append(FlutterStandardTypedData(bytes: bytes))
          }
        } else {
          guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width.isFinite, height.isFinite, width > 0, height > 0, width * height <= 60_000_000 else { throw ReceiptError.invalid }
          let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceShouldCacheImmediately: true]
          guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ReceiptError.invalid }
          let image = UIImage(cgImage: thumbnail)
          guard let bytes = image.jpegData(compressionQuality: 0.88) else { throw ReceiptError.invalid }
          images.append(FlutterStandardTypedData(bytes: bytes))
        }
        DispatchQueue.main.async { result(images) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "receipt_decode_failed", message: "Choose a readable, unlocked PDF or image below 60 MB.", details: nil)) }
      }
    }
  }
  private enum ReceiptError: Error { case invalid }
}
