import Flutter
import UIKit
import UniformTypeIdentifiers

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
    let registrar: FlutterPluginRegistrar? =
      engineBridge.pluginRegistry.registrar(forPlugin: "FolderAccessPlugin")
    if let registrar {
      FolderAccessPlugin.register(with: registrar)
    }
  }
}

/// Lets Dart read a folder the user picks in Files. iOS hands out such a
/// folder as a security-scoped URL: nothing inside it is readable until
/// access is started, and it only survives a relaunch as a saved bookmark.
class FolderAccessPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private static let bookmarkKey = "library_folder_bookmark"

  private var pendingResult: FlutterResult?
  private var openURL: URL?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "musify/folder_access",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(FolderAccessPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pick":
      pick(result)
    case "restore":
      result(restore())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pendingResult == nil, let presenter = topViewController() else {
      result(FlutterError(code: "busy", message: "Folder picker unavailable", details: nil))
      return
    }
    pendingResult = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let url = urls.first else {
      finish(nil)
      return
    }
    open(url)
    if let bookmark = try? url.bookmarkData(
      options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    {
      UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
    }
    finish(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  private func finish(_ value: Any?) {
    pendingResult?(value)
    pendingResult = nil
  }

  /// Reopens the last picked folder. Its path can change between launches
  /// (the container moves on reinstall), so Dart takes the path from here.
  private func restore() -> String? {
    guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return nil }
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else {
      return nil
    }
    open(url)
    if stale,
      let fresh = try? url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    {
      UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
    }
    return url.path
  }

  /// Access stays open for the app's life so the scanner (and later the
  /// player) can read files; only the current library folder is kept open.
  private func open(_ url: URL) {
    if openURL == url { return }
    if url.startAccessingSecurityScopedResource() {
      openURL?.stopAccessingSecurityScopedResource()
      openURL = url
    }
  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
      .first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
