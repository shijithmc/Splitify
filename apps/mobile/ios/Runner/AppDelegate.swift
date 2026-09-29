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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SpendingNative") {
      SpendingNative.register(with: registrar)
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


/// PDF parsing is local. Passwords and extracted text never leave this channel.
final class SpendingNative: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "app.hisaab/spending", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(SpendingNative(), channel: channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "pdfText", let arguments = call.arguments as? [String: Any], let path = arguments["path"] as? String else {
      result(FlutterMethodNotImplemented); return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let file = URL(fileURLWithPath: path)
      let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
      guard fileSize <= 20 * 1024 * 1024, let pdf = PDFDocument(url: file) else {
        DispatchQueue.main.async { result(FlutterError(code: "pdf_unreadable", message: "Choose a readable text PDF below 20 MB and 200 pages, or import a CSV statement.", details: nil)) }; return
      }
      if pdf.isLocked && !pdf.unlock(withPassword: arguments["password"] as? String ?? "") {
        DispatchQueue.main.async { result(FlutterError(code: "pdf_password", message: "This PDF needs the correct statement password.", details: nil)) }; return
      }
      guard pdf.pageCount > 0, pdf.pageCount <= 200 else {
        DispatchQueue.main.async { result(FlutterError(code: "pdf_unreadable", message: "Choose a statement with 1 to 200 pages, or import a CSV statement.", details: nil)) }; return
      }
      var text = ""
      for index in 0..<pdf.pageCount {
        if let content = pdf.page(at: index)?.string { text += content + "\n" }
        if text.utf8.count > 2 * 1024 * 1024 {
          DispatchQueue.main.async { result(FlutterError(code: "pdf_too_large", message: "Choose a shorter statement with less than 2 MB of text.", details: nil)) }; return
        }
      }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        DispatchQueue.main.async { result(FlutterError(code: "pdf_no_text", message: "This PDF has no readable text. Use a CSV statement or add a transaction.", details: nil)) }; return
      }
      DispatchQueue.main.async { result(text) }
    }
  }
}
