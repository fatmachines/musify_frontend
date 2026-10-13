import Flutter
import Intents
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
    let siriRegistrar: FlutterPluginRegistrar? =
      engineBridge.pluginRegistry.registrar(forPlugin: "SiriBridge")
    if let siriRegistrar {
      SiriBridge.shared.attach(messenger: siriRegistrar.messenger())
    }
  }

  // Siri: "Play X on Musify" is handled inside the app (no extension).

  // FlutterAppDelegate already implements these (forwarding to plugins), so
  // Musify takes the play requests and passes anything else on.

  override func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
    NSLog("[Musify] siri: handlerFor %@", String(describing: type(of: intent)))
    if intent is INPlayMediaIntent { return SiriBridge.shared }
    return super.application(application, handlerFor: intent)
  }

  override func application(
    _ application: UIApplication,
    handle intent: INIntent,
    completionHandler: @escaping (INIntentResponse) -> Void
  ) {
    guard let intent = intent as? INPlayMediaIntent else {
      super.application(application, handle: intent, completionHandler: completionHandler)
      return
    }
    NSLog("[Musify] siri: handling in the app")
    SiriBridge.shared.play(intent)
    completionHandler(INPlayMediaIntentResponse(code: .success, userActivity: nil))
  }
}

/// Siri's "Play X on Musify". Siri hands over what was said (a song,
/// playlist, artist or album name); the Dart side (VoicePlay) searches the
/// library and plays it, over the "musify/siri" channel.
///
/// Dart has to be running to play. If Musify is running, Siri's request is
/// handled in the background; if not, Siri opens Musify and the request
/// waits here until Dart reports it is ready.
final class SiriBridge: NSObject, INPlayMediaIntentHandling {
  static let shared = SiriBridge()

  private var channel: FlutterMethodChannel?

  // Siri calls the handler on a background thread while Flutter runs on
  // the main one: this state is shared under a lock, and Flutter is only
  // ever called on the main thread.
  private let lock = NSLock()
  private var _dartReady = false
  private var pending: [[String: Any]] = []

  private var dartReady: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _dartReady
  }

  /// iOS kills the app if it touches Siri APIs like INVocabulary without
  /// the Siri capability. A request from Siri proves it is enabled, so the
  /// names are only handed over once one has arrived (remembered across
  /// launches).
  private static let siriSeenKey = "musify_siri_request_seen"
  private var siriEnabled = UserDefaults.standard.bool(forKey: siriSeenKey)
  private var vocabulary: (playlists: [String], artists: [String])?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "musify/siri", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "ready":
        self.lock.lock()
        self._dartReady = true
        let waiting = self.pending
        self.pending = []
        self.lock.unlock()
        NSLog("[Musify] siri: Dart ready, %d waiting", waiting.count)
        waiting.forEach(self.send)
        result(nil)
      case "vocabulary":
        // Helps Siri recognise the library's own names.
        let args = call.arguments as? [String: Any]
        self.vocabulary = (
          playlists: args?["playlists"] as? [String] ?? [],
          artists: args?["artists"] as? [String] ?? []
        )
        self.applyVocabulary()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // Playing media through Siri needs no permission prompt (unlike other
    // Siri requests), only the Siri capability on the app.
    self.channel = channel
  }

  private func applyVocabulary() {
    guard siriEnabled, let vocabulary else { return }
    INVocabulary.shared().setVocabularyStrings(
      NSOrderedSet(array: vocabulary.playlists), of: .mediaPlaylistTitle)
    INVocabulary.shared().setVocabularyStrings(
      NSOrderedSet(array: vocabulary.artists), of: .mediaMusicArtistName)
  }

  /// Called on every request from Siri, which only arrive with the Siri
  /// capability enabled.
  private func siriIsEnabled() {
    DispatchQueue.main.async {
      guard !self.siriEnabled else { return }
      self.siriEnabled = true
      UserDefaults.standard.set(true, forKey: Self.siriSeenKey)
      self.applyVocabulary()
    }
  }

  // INPlayMediaIntentHandling ---------------------------------------------------

  /// The library is searched when playing, so Siri is told the request
  /// itself is fine.
  func resolveMediaItems(
    for intent: INPlayMediaIntent,
    with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
  ) {
    siriIsEnabled()
    NSLog("[Musify] siri: resolve %@", String(describing: intent.mediaSearch))
    let search = intent.mediaSearch
    let title = search?.mediaName ?? search?.artistName ?? search?.albumName ?? "Musify"
    let item = INMediaItem(
      identifier: "musify-request",
      title: title,
      type: search?.mediaType ?? .music,
      artwork: nil,
      artist: search?.artistName)
    completion(INPlayMediaMediaItemResolutionResult.successes(with: [item]))
  }

  func handle(
    intent: INPlayMediaIntent,
    completion: @escaping (INPlayMediaIntentResponse) -> Void
  ) {
    siriIsEnabled()
    let ready = dartReady
    NSLog("[Musify] siri: handle (Dart ready: %@)", ready ? "yes" : "no")
    if ready {
      // Played in the background by application(_:handle:completionHandler:).
      completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil))
    } else {
      // Not running: open Musify; the request waits until Dart is ready.
      play(intent)
      completion(INPlayMediaIntentResponse(code: .continueInApp, userActivity: nil))
    }
  }

  func play(_ intent: INPlayMediaIntent) {
    let search = intent.mediaSearch
    var request: [String: Any] = ["type": Self.kind(search?.mediaType)]
    if let name = search?.mediaName ?? search?.albumName { request["query"] = name }
    if let artist = search?.artistName { request["artist"] = artist }
    if let shuffle = intent.playShuffled { request["shuffle"] = shuffle }
    NSLog("[Musify] siri: request %@", request.description)
    lock.lock()
    let ready = _dartReady
    if !ready { pending.append(request) }
    lock.unlock()
    if ready { send(request) }
  }

  private func send(_ request: [String: Any]) {
    DispatchQueue.main.async {
      guard let channel = self.channel else {
        NSLog("[Musify] siri: no channel to Dart")
        return
      }
      channel.invokeMethod("play", arguments: request) { result in
        NSLog("[Musify] siri: Dart played: %@", String(describing: result))
      }
    }
  }

  /// Matches VoiceKind in voice_play.dart.
  private static func kind(_ type: INMediaItemType?) -> String {
    switch type {
    case .song: return "song"
    case .playlist: return "playlist"
    case .artist: return "artist"
    case .album: return "album"
    default: return "any"
    }
  }
}

/// Lets Dart read the folders the user picks in Files. iOS hands out such a
/// folder as a security-scoped URL: nothing inside it is readable until
/// access is started, and it only survives a relaunch as a saved bookmark.
/// Each library folder gets its own bookmark, kept in an ordered list.
///
/// Every reply is a map that includes "log", lines for the app's debug log.
class FolderAccessPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private static let bookmarksKey = "library_folder_bookmarks"
  // Before several folders were supported there was a single bookmark.
  private static let legacyKey = "library_folder_bookmark"

  private var pendingResult: FlutterResult?
  private var openURLs: [String: URL] = [:]
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
    let defaults = UserDefaults.standard
    if let entries = defaults.array(forKey: Self.bookmarksKey) as? [[String: Any]] {
      return entries
    }
    if let legacy = defaults.data(forKey: Self.legacyKey) {
      let entries: [[String: Any]] = [["id": UUID().uuidString, "bookmark": legacy]]
      saveEntries(entries)
      defaults.removeObject(forKey: Self.legacyKey)
      note("migrated the single saved folder")
      return entries
    }
    return []
  }

  private func saveEntries(_ entries: [[String: Any]]) {
    UserDefaults.standard.set(entries, forKey: Self.bookmarksKey)
  }

  private func bookmark(_ url: URL) -> Data? {
    do {
      return try url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    } catch {
      note("bookmark failed: \(error)")
      return nil
    }
  }

  // Picking ---------------------------------------------------------------------

  private func pick(_ result: @escaping FlutterResult) {
    guard pendingResult == nil, let presenter = topViewController() else {
      note("pick: no presenter (pending=\(pendingResult != nil))")
      result(reply([:]))
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
    // Picking a folder that is already in the library reuses its entry.
    for (id, existing) in openURLs
    where existing.standardizedFileURL == url.standardizedFileURL {
      note("pick: already added as \(id)")
      describe(url)
      finish(["id": id, "path": existing.path])
      return
    }
    let id = UUID().uuidString
    open(url, id: id)
    if let data = bookmark(url) {
      saveEntries(loadEntries() + [["id": id, "bookmark": data]])
      note("pick: bookmark saved (\(data.count) bytes)")
    }
    describe(url)
    finish(["id": id, "path": url.path])
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    note("pick: cancelled")
    finish(nil)
  }

  private func finish(_ folder: [String: Any]?) {
    var values: [String: Any] = [:]
    if let folder { values["folder"] = folder }
    pendingResult?(reply(values))
    pendingResult = nil
  }

  // Restoring and removing ------------------------------------------------------

  /// Reopens every saved folder. Paths can change between launches (the
  /// container moves on reinstall), so Dart takes them from here.
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
        url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
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

  /// Access stays open for the app's life so the scanner and player can read
  /// files in every library folder.
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

  /// What iOS itself can list in the folder, to compare with the Dart scan.
  private func describe(_ url: URL) {
    do {
      let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
      note("list: \(names.count) entries, e.g. \(names.prefix(5))")
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
