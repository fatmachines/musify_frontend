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
    } else {
      NSLog("[Musify] no registrar for FolderAccessPlugin")
    }
  }
}

/// Lets Dart read a folder the user picks in Files. iOS hands out such a
/// folder as a security-scoped URL: nothing inside it is readable until
/// access is started, and it only survives a relaunch as a saved bookmark.
///
/// Both calls answer {path, log}; the log lines end up in the app's debug log.
class FolderAccessPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private static let bookmarkKey = "library_folder_bookmark"

  private var pendingResult: FlutterResult?
  private var openURL: URL?
  private var log: [String] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "musify/folder_access",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(FolderAccessPlugin(), channel: channel)
    NSLog("[Musify] FolderAccessPlugin registered")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    log = []
    switch call.method {
    case "pick":
      pick(result)
    case "restore":
      let path = restore()
      result(reply(path))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func note(_ line: String) {
    NSLog("[Musify] %@", line)
    log.append(line)
  }

  private func reply(_ path: String?) -> [String: Any] {
    var value: [String: Any] = ["log": log]
    if let path { value["path"] = path }
    return value
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pendingResult == nil, let presenter = topViewController() else {
      note("pick: no presenter (pending=\(pendingResult != nil))")
      result(reply(nil))
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
    note("pick: urls=\(urls.map { $0.absoluteString })")
    guard let url = urls.first else {
      finish(nil)
      return
    }
    open(url)
    do {
      let bookmark = try url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
      note("pick: bookmark saved (\(bookmark.count) bytes)")
    } catch {
      note("pick: bookmark failed: \(error)")
    }
    describe(url)
    finish(url.path)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    note("pick: cancelled")
    finish(nil)
  }

  private func finish(_ path: String?) {
    pendingResult?(reply(path))
    pendingResult = nil
  }

  /// Reopens the last picked folder. Its path can change between launches
  /// (the container moves on reinstall), so Dart takes the path from here.
  private func restore() -> String? {
    guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
      note("restore: no bookmark saved")
      return nil
    }
    var stale = false
    let url: URL
    do {
      url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    } catch {
      note("restore: bookmark resolve failed: \(error)")
      return nil
    }
    note("restore: url=\(url.absoluteString) stale=\(stale)")
    open(url)
    if stale,
      let fresh = try? url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    {
      UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
    }
    describe(url)
    return url.path
  }

  /// Access stays open for the app's life so the scanner (and later the
  /// player) can read files; only the current library folder is kept open.
  private func open(_ url: URL) {
    if openURL == url {
      note("open: already open")
      return
    }
    let started = url.startAccessingSecurityScopedResource()
    note("open: startAccessingSecurityScopedResource=\(started)")
    if started {
      openURL?.stopAccessingSecurityScopedResource()
      openURL = url
    }
  }

  /// What iOS itself can list in the folder, to compare with the Dart scan.
  private func describe(_ url: URL) {
    do {
      let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
      note("list: \(names.count) entries, e.g. \(names.prefix(5))")
      if let first = names.first(where: { !$0.hasPrefix(".") }) {
        let child = url.appendingPathComponent(first)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir)
        if isDir.boolValue {
          let inner = try FileManager.default.contentsOfDirectory(atPath: child.path)
          note("list: [\(first)] \(inner.count) entries, e.g. \(inner.prefix(5))")
        }
      }
    } catch {
      note("list: failed: \(error)")
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
