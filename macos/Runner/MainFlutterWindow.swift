import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Room for the library sidebar, the page and the player bar.
    self.minSize = NSSize(width: 800, height: 600)
    self.title = "Musify"

    RegisterGeneratedPlugins(registry: flutterViewController)
    FolderAccessPlugin.register(
      with: flutterViewController.registrar(forPlugin: "FolderAccessPlugin"))

    super.awakeFromNib()
  }
}

/// Library folders on the Mac, as on iPhone (ios/Runner/AppDelegate.swift):
/// the app is sandboxed, so a folder is only readable (and writable, for
/// downloads) once picked in the open panel. Each one is kept as a
/// security-scoped bookmark, so access survives relaunches, in an ordered
/// list.
///
/// Every reply is a map that includes "log", lines for the app's debug log.
class FolderAccessPlugin: NSObject, FlutterPlugin {
  private static let bookmarksKey = "library_folder_bookmarks"

  private var openURLs: [String: URL] = [:]
  private var log: [String] = []
  private var picking = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "musify/folder_access",
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(FolderAccessPlugin(), channel: channel)
    NSLog("[Musify] FolderAccessPlugin registered")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    log = []
    switch call.method {
    case "pick":
      pick(result)
    case "restoreAll":
      result(reply(["folders": restoreAll()]))
    case "remove":
      if let args = call.arguments as? [String: Any], let id = args["id"] as? String {
        remove(id)
      }
      result(reply([:]))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func note(_ line: String) {
    NSLog("[Musify] %@", line)
    log.append(line)
  }

  private func reply(_ values: [String: Any]) -> [String: Any] {
    var value = values
    value["log"] = log
    return value
  }

  // Saved bookmarks: [{"id": String, "bookmark": Data}] in the order added.

  private func loadEntries() -> [[String: Any]] {
    UserDefaults.standard.array(forKey: Self.bookmarksKey) as? [[String: Any]] ?? []
  }

  private func saveEntries(_ entries: [[String: Any]]) {
    UserDefaults.standard.set(entries, forKey: Self.bookmarksKey)
  }

  private func bookmark(_ url: URL) -> Data? {
    do {
      return try url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    } catch {
      note("bookmark failed: \(error)")
      return nil
    }
  }

  // Picking ---------------------------------------------------------------------

  private func pick(_ result: @escaping FlutterResult) {
    guard !picking else {
      note("pick: already picking")
      result(reply([:]))
      return
    }
    picking = true
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Add"
    panel.message = "Choose a music folder"
    let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      self.picking = false
      guard response == .OK, let url = panel.url else {
        self.note("pick: cancelled")
        result(self.reply([:]))
        return
      }
      result(self.reply(["folder": self.add(url)]))
    }
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: done)
    } else {
      panel.begin(completionHandler: done)
    }
  }

  private func add(_ url: URL) -> [String: Any] {
    note("pick: url=\(url.absoluteString)")
    // Picking a folder that is already in the library reuses its entry.
    for (id, existing) in openURLs
    where existing.standardizedFileURL == url.standardizedFileURL {
      note("pick: already added as \(id)")
      return ["id": id, "path": existing.path]
    }
    let id = UUID().uuidString
    open(url, id: id)
    if let data = bookmark(url) {
      saveEntries(loadEntries() + [["id": id, "bookmark": data]])
      note("pick: bookmark saved (\(data.count) bytes)")
    }
    describe(url)
    return ["id": id, "path": url.path]
  }

  // Restoring and removing ------------------------------------------------------

  private func restoreAll() -> [[String: Any]] {
    var entries = loadEntries()
    var folders: [[String: Any]] = []
    for (index, entry) in entries.enumerated() {
      guard let id = entry["id"] as? String, let data = entry["bookmark"] as? Data else {
        continue
      }
      var stale = false
      let url: URL
      do {
        url = try URL(
          resolvingBookmarkData: data, options: .withSecurityScope,
          relativeTo: nil, bookmarkDataIsStale: &stale)
      } catch {
        note("restore: \(id) failed to resolve: \(error)")
        continue
      }
      note("restore: \(id) url=\(url.absoluteString) stale=\(stale)")
      open(url, id: id)
      if stale, let fresh = bookmark(url) {
        entries[index]["bookmark"] = fresh
      }
      describe(url)
      folders.append(["id": id, "path": url.path])
    }
    saveEntries(entries)
    if entries.isEmpty { note("restore: no folders saved") }
    return folders
  }

  private func remove(_ id: String) {
    openURLs[id]?.stopAccessingSecurityScopedResource()
    openURLs[id] = nil
    saveEntries(loadEntries().filter { ($0["id"] as? String) != id })
    note("remove: \(id)")
  }

  /// Access stays open for the app's life so the scanner, the player and
  /// downloads can use every library folder.
  private func open(_ url: URL, id: String) {
    if openURLs[id] == url {
      note("open: already open")
      return
    }
    let started = url.startAccessingSecurityScopedResource()
    note("open: startAccessingSecurityScopedResource=\(started)")
    if started {
      openURLs[id]?.stopAccessingSecurityScopedResource()
      openURLs[id] = url
    }
  }

  private func describe(_ url: URL) {
    do {
      let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
      note("list: \(names.count) entries, e.g. \(names.prefix(5))")
    } catch {
      note("list: failed: \(error)")
    }
  }
}
