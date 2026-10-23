import CarPlay
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
    let carPlayRegistrar: FlutterPluginRegistrar? =
      engineBridge.pluginRegistry.registrar(forPlugin: "CarPlayBridge")
    if let carPlayRegistrar {
      CarPlayBridge.shared.attach(messenger: carPlayRegistrar.messenger())
    }
  }

  // Siri: "Play X on Musify" is handled inside the app (no extension).

  // FlutterAppDelegate already implements these (forwarding to plugins), so
  // Musify takes the play requests and passes anything else on.

  override func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
    SiriBridge.note("handlerFor \(type(of: intent))")
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
    SiriBridge.note("handling in the app")
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

  /// Siri's steps, also kept on the phone (last 60 lines) so they reach the
  /// app's debug log even when Siri ran with nothing attached.
  private static let logKey = "musify_siri_log"

  static func note(_ line: String) {
    NSLog("[Musify] siri: %@", line)
    let stamp = ISO8601DateFormatter().string(from: Date())
    var lines = UserDefaults.standard.stringArray(forKey: logKey) ?? []
    lines.append("\(stamp) \(line)")
    UserDefaults.standard.set(Array(lines.suffix(60)), forKey: logKey)
  }

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
  private var siriEnabled =
    UserDefaults.standard.bool(forKey: siriSeenKey) && SiriBridge.siriAllowed

  /// Whether this build may use Siri at all: its provisioning profile lists
  /// the Siri entitlement. A request seen by an earlier build that had it
  /// doesn't count once the capability is gone (that crashed on launch).
  /// App Store builds carry no profile: then only a request decides.
  static let siriAllowed: Bool = {
    guard
      let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
      let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .isoLatin1),
      let start = text.range(of: "<?xml"),
      let end = text.range(of: "</plist>"),
      let plist = try? PropertyListSerialization.propertyList(
        from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil)
        as? [String: Any],
      let entitlements = plist["Entitlements"] as? [String: Any]
    else { return true }
    let allowed = entitlements["com.apple.developer.siri"] != nil
    if !allowed { NSLog("[Musify] siri: not in this build's capabilities") }
    return allowed
  }()
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
        SiriBridge.note("Dart ready, \(waiting.count) waiting")
        waiting.forEach(self.send)
        result(nil)
      case "log":
        // Hands the saved steps to Dart's debug log, then starts afresh.
        result(UserDefaults.standard.stringArray(forKey: Self.logKey) ?? [])
        UserDefaults.standard.removeObject(forKey: Self.logKey)
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
      guard !self.siriEnabled, SiriBridge.siriAllowed else { return }
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
    SiriBridge.note("resolve \(String(describing: intent.mediaSearch))")
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
    SiriBridge.note("handle (Dart ready: \(ready))")
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
    SiriBridge.note("request \(request)")
    lock.lock()
    let ready = _dartReady
    if !ready { pending.append(request) }
    lock.unlock()
    if ready { send(request) }
  }

  private func send(_ request: [String: Any]) {
    DispatchQueue.main.async {
      guard let channel = self.channel else {
        SiriBridge.note("no channel to Dart")
        return
      }
      channel.invokeMethod("play", arguments: request) { result in
        SiriBridge.note("Dart played: \(String(describing: result))")
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

/// CarPlay's screens, in the style of Spotify's: tabs for Home, Recently
/// Played and Your Library; Home has the greeting over a row of recent
/// covers, then what's playing, pinned, playlists and folders. The car
/// connects its own scene (Info.plist,
/// CPTemplateApplicationSceneSessionRoleApplication); the lists come from
/// Dart (CarPlay in car_play.dart) over the "musify/carplay" channel. Now
/// Playing is CarPlay's own screen, fed by audio_service like the lock
/// screen, with Musify's buttons (see setUpNowPlaying).
final class CarPlayBridge: NSObject {
  static let shared = CarPlayBridge()

  private var channel: FlutterMethodChannel?
  private(set) var dartReady = false
  /// The car's screens, to reload when Dart starts or the library changes.
  var onChange: (() -> Void)?

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "musify/carplay", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "ready", "changed":
        self?.dartReady = true
        self?.onChange?()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  /// Dart's answer, or nil when Dart isn't running (or failed).
  func call(_ method: String, _ arguments: Any? = nil, completion: @escaping (Any?) -> Void) {
    guard dartReady, let channel else { return completion(nil) }
    channel.invokeMethod(method, arguments: arguments) { result in
      completion(result is FlutterError ? nil : result)
    }
  }
}

/// One row from Dart (see car_play.dart).
struct CarEntry {
  let id: String
  let title: String
  let subtitle: String?
  let playable: Bool
  let art: String
  let color: UIColor?
  let images: [String]

  init(_ map: [String: Any]) {
    id = map["id"] as? String ?? ""
    title = map["title"] as? String ?? ""
    subtitle = map["subtitle"] as? String
    playable = map["playable"] as? Bool ?? true
    art = map["art"] as? String ?? "song"
    images = map["images"] as? [String] ?? []
    if let argb = (map["color"] as? NSNumber)?.uint32Value {
      color = UIColor(
        red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
        blue: CGFloat(argb & 0xFF) / 255, alpha: 1)
    } else {
      color = nil
    }
  }

  static func list(_ value: Any?) -> [CarEntry] {
    (value as? [[String: Any]] ?? []).map(CarEntry.init)
  }
}

/// Square artwork as the app draws it: the playlist's 2x2 mosaic of
/// covers, Liked Songs' heart on its gradient, a tag's colour.
enum CarArtwork {
  static func image(_ entry: CarEntry, side: CGFloat = 240) -> UIImage {
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    let covers = entry.images.prefix(4).compactMap { UIImage(contentsOfFile: $0) }
    return UIGraphicsImageRenderer(size: rect.size).image { context in
      switch entry.art {
      case "liked":
        let colors = [0x450AF5, 0x8E8EE5, 0xC4EFD9].map { rgb($0).cgColor } as CFArray
        if let gradient = CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil)
        {
          context.cgContext.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        }
        symbol("heart.fill", in: rect)
      case "tag":
        (entry.color ?? rgb(0x535353)).setFill()
        context.fill(rect)
        symbol("tag.fill", in: rect)
      default:
        if covers.count >= 4 {
          let half = side / 2
          for (i, cover) in covers.enumerated() {
            fill(cover, in: CGRect(
              x: CGFloat(i % 2) * half, y: CGFloat(i / 2) * half, width: half, height: half))
          }
        } else if let cover = covers.first {
          fill(cover, in: rect)
        } else {
          rgb(0x282828).setFill()
          context.fill(rect)
          symbol(entry.art == "folder" ? "folder.fill" : "music.note", in: rect, alpha: 0.6)
        }
      }
    }
  }

  private static func rgb(_ value: Int) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  /// Draws [image] filling [rect], cropped to keep its shape (YouTube
  /// thumbnails are wide).
  private static func fill(_ image: UIImage, in rect: CGRect) {
    let scale = max(rect.width / image.size.width, rect.height / image.size.height)
    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    UIGraphicsGetCurrentContext()?.saveGState()
    UIRectClip(rect)
    image.draw(in: CGRect(
      x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
      width: size.width, height: size.height))
    UIGraphicsGetCurrentContext()?.restoreGState()
  }

  private static func symbol(_ name: String, in rect: CGRect, alpha: CGFloat = 1) {
    let config = UIImage.SymbolConfiguration(pointSize: rect.width * 0.36, weight: .semibold)
    guard
      let image = UIImage(systemName: name, withConfiguration: config)?
        .withTintColor(UIColor.white.withAlphaComponent(alpha), renderingMode: .alwaysOriginal)
    else { return }
    image.draw(at: CGPoint(
      x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2))
  }

  /// Draws [entries]' artwork off the main thread.
  static func images(
    _ entries: [CarEntry], side: CGFloat = 240, completion: @escaping ([UIImage]) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let images = entries.map { image($0, side: side) }
      DispatchQueue.main.async { completion(images) }
    }
  }
}

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
  CPTabBarTemplateDelegate, CPNowPlayingTemplateObserver
{
  private var interfaceController: CPInterfaceController?
  private var tabs: CPTabBarTemplate?
  private let home = CPListTemplate(title: "Home", sections: [])
  private let recent = CPListTemplate(title: "Recently Played", sections: [])
  private let library = CPListTemplate(title: "Your Library", sections: [])

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    for (template, symbol) in [
      (home, "house.fill"),
      (recent, "clock.fill"),
      (library, "books.vertical.fill"),
    ] {
      template.tabTitle = template.title
      template.tabImage = UIImage(systemName: symbol)
      template.emptyViewTitleVariants = ["Nothing here yet"]
    }
    let tabs = CPTabBarTemplate(templates: [home, recent, library])
    tabs.delegate = self
    self.tabs = tabs
    interfaceController.setRootTemplate(tabs, animated: false, completion: nil)
    setUpNowPlaying()
    CarPlayBridge.shared.onChange = { [weak self] in self?.reloadAll() }
    reloadAll()
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    CPNowPlayingTemplate.shared.remove(self)
    self.interfaceController = nil
    self.tabs = nil
    CarPlayBridge.shared.onChange = nil
  }

  func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
    if selectedTemplate === home { reloadHome() }
  }

  private func reloadAll() {
    reloadHome()
    reloadRecent()
    reloadLibrary()
  }

  /// Opened from the car with the app not running yet: Dart says "ready"
  /// once it is, which reloads everything.
  private func showNotRunning(_ template: CPListTemplate) {
    let item = CPListItem(
      text: "Open Musify on your iPhone",
      detailText: "Your music shows here once it's running")
    template.updateSections([CPListSection(items: [item])])
  }

  // The tabs -------------------------------------------------------------------

  /// Like Spotify's: the greeting over a row of recent covers, then
  /// what's playing, what's pinned, the playlists and folders.
  private func reloadHome() {
    CarPlayBridge.shared.call("home") { [weak self] result in
      guard let self else { return }
      guard let map = result as? [String: Any] else { return self.showNotRunning(self.home) }
      let greeting = map["greeting"] as? String ?? "Musify"
      let now = (map["nowPlaying"] as? [String: Any]).map(CarEntry.init)
      let recent = Array(CarEntry.list(map["recent"]).prefix(CPMaximumNumberOfGridImages))
      let lists: [(String, [CarEntry])] = [
        ("Pinned", CarEntry.list(map["pinned"])),
        ("Your playlists", CarEntry.list(map["playlists"])),
        ("Your folders", CarEntry.list(map["folders"])),
      ]
      let side = CPListImageRowItem.maximumImageSize.width * 3
      CarArtwork.images(recent, side: max(side, 120)) { covers in
        var sections: [CPListSection] = []
        if let now {
          let item = self.listItems([now]).first!
          item.isPlaying = true
          sections.append(CPListSection(items: [item]))
        }
        let row = CPListImageRowItem(text: greeting, images: covers)
        row.handler = { [weak self] _, done in
          self?.showRecent()
          done()
        }
        row.listImageRowHandler = { [weak self] _, index, done in
          self?.open(recent[index], done: done)
        }
        sections.append(CPListSection(items: [row]))
        for (header, entries) in lists where !entries.isEmpty {
          sections.append(self.section(header, self.listItems(entries)))
        }
        self.home.updateSections(sections)
      }
    }
  }

  private func showRecent() {
    if #available(iOS 17.0, *) {
      tabs?.select(recent)
    } else {
      CarPlayBridge.shared.call("recent") { [weak self] result in
        guard let self else { return }
        let items = self.listItems(CarEntry.list(result))
        self.push(CPListTemplate(title: "Recently Played", sections: [CPListSection(items: items)]))
      }
    }
  }

  private func reloadRecent() {
    CarPlayBridge.shared.call("recent") { [weak self] result in
      guard let self else { return }
      guard result != nil else { return self.showNotRunning(self.recent) }
      self.recent.updateSections([CPListSection(items: self.listItems(CarEntry.list(result)))])
    }
  }

  private func reloadLibrary() {
    CarPlayBridge.shared.call("library") { [weak self] result in
      guard let self else { return }
      guard let map = result as? [String: Any] else { return self.showNotRunning(self.library) }
      let sections = [("Playlists", "playlists"), ("Folders", "folders"), ("Tags", "tags")]
        .compactMap { pair -> CPListSection? in
          let (header, key) = pair
          let entries = CarEntry.list(map[key])
          return entries.isEmpty ? nil : self.section(header, self.listItems(entries))
        }
      self.library.updateSections(sections)
    }
  }

  private func section(_ header: String, _ items: [CPListTemplateItem]) -> CPListSection {
    CPListSection(
      items: items, header: header, headerSubtitle: nil, headerImage: nil, headerButton: nil,
      sectionIndexTitle: nil)
  }

  /// Rows that get their artwork once it's drawn (lists can be long).
  private func listItems(_ entries: [CarEntry], in playlist: String? = nil) -> [CPListItem] {
    let shown = Array(entries.prefix(CPListTemplate.maximumItemCount))
    let items = shown.map { entry in
      let item = CPListItem(text: entry.title, detailText: entry.subtitle)
      if !entry.playable { item.accessoryType = .disclosureIndicator }
      item.handler = { [weak self] _, done in
        self?.select(entry, in: playlist, done: done)
      }
      return item
    }
    CarArtwork.images(shown, side: 120) { images in
      for (item, image) in zip(items, images) { item.setImage(image) }
    }
    return items
  }

  private func select(_ entry: CarEntry, in playlist: String? = nil, done: @escaping () -> Void) {
    if entry.id == "now-playing" {
      showNowPlaying()
      done()
    } else if entry.playable {
      play(["id": entry.id, "playlist": playlist ?? NSNull()], done: done)
    } else {
      open(entry, done: done)
    }
  }

  /// A playlist: Shuffle, then its songs.
  private func open(_ entry: CarEntry, done: @escaping () -> Void) {
    CarPlayBridge.shared.call("children", entry.id) { [weak self] result in
      defer { done() }
      guard let self, let interfaceController = self.interfaceController else { return }
      let shuffle = CPListItem(
        text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
      shuffle.handler = { [weak self] _, done in
        self?.play(["id": entry.id, "playlist": entry.id, "shuffle": true], done: done)
      }
      let songs = self.listItems(CarEntry.list(result), in: entry.id)
      let list = CPListTemplate(
        title: entry.title,
        sections: [CPListSection(items: [shuffle]), CPListSection(items: songs)])
      interfaceController.pushTemplate(list, animated: true, completion: nil)
    }
  }

  /// Plays (a song with the rest of its playlist after it, or the playlist
  /// shuffled) and shows Now Playing.
  private func play(_ request: [String: Any], done: @escaping () -> Void) {
    CarPlayBridge.shared.call("play", request) { [weak self] _ in
      self?.showNowPlaying()
      done()
    }
  }

  private func showNowPlaying() {
    guard let interfaceController else { return }
    let nowPlaying = CPNowPlayingTemplate.shared
    if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
      interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
    } else {
      interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }
  }

  // Now Playing ------------------------------------------------------------------

  /// CarPlay's own Now Playing screen (cover, controls and progress from
  /// audio_service), with Queue at the top and buttons to add the song to
  /// a playlist, tag it, and download it (YouTube songs).
  private func setUpNowPlaying() {
    let nowPlaying = CPNowPlayingTemplate.shared
    nowPlaying.isUpNextButtonEnabled = true
    nowPlaying.upNextTitle = "Queue"
    nowPlaying.isAlbumArtistButtonEnabled = false
    nowPlaying.add(self)
    func button(_ symbol: String, _ action: @escaping () -> Void) -> CPNowPlayingButton {
      let image = UIImage(systemName: symbol) ?? UIImage()
      return CPNowPlayingImageButton(image: image) { _ in action() }
    }
    nowPlaying.updateNowPlayingButtons([
      button("text.badge.plus") { [weak self] in self?.showAddToPlaylist() },
      button("tag") { [weak self] in self?.showTags() },
      button("arrow.down.circle") { [weak self] in self?.showDownload() },
    ])
  }

  func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    CarPlayBridge.shared.call("queue") { [weak self] result in
      guard let self, let map = result as? [String: Any] else { return }
      let queued = CarEntry.list(map["queued"])
      let rest = CarEntry.list(map["rest"])
      var sections: [CPListSection] = []
      for (header, entries) in [
        ("Next in queue", queued),
        ((map["from"] as? String).map { "Next from: \($0)" } ?? "Next up", rest),
      ] where !entries.isEmpty {
        let items = self.listItems(entries)
        for (item, entry) in zip(items, entries) {
          item.handler = { [weak self] _, done in
            CarPlayBridge.shared.call("jump", Int(entry.id) ?? 0) { _ in
              self?.showNowPlaying()
              done()
            }
          }
        }
        sections.append(self.section(header, items))
      }
      if sections.isEmpty {
        sections = [CPListSection(items: [CPListItem(text: "Nothing up next", detailText: nil)])]
      }
      self.push(CPListTemplate(title: "Queue", sections: sections))
    }
  }

  func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

  private func push(_ template: CPTemplate) {
    interfaceController?.pushTemplate(template, animated: true, completion: nil)
  }

  /// A list of choices from Dart ({items} or a {note} saying why not),
  /// each ticked when "on".
  private func choices(
    _ method: String, title: String, onTap: @escaping (CarEntry, CPListItem) -> Void
  ) {
    CarPlayBridge.shared.call(method) { [weak self] result in
      guard let self else { return }
      let map = result as? [String: Any] ?? [:]
      let raw = map["items"] as? [[String: Any]] ?? []
      guard !raw.isEmpty else {
        let note = map["note"] as? String ?? "Open Musify on your iPhone"
        let item = CPListItem(text: note, detailText: nil)
        return self.push(CPListTemplate(title: title, sections: [CPListSection(items: [item])]))
      }
      let entries = raw.map(CarEntry.init)
      let items = self.listItems(entries)
      for (index, item) in items.enumerated() {
        let entry = entries[index]
        self.tick(item, raw[index]["on"] as? Bool ?? false)
        item.accessoryType = .none
        item.handler = { [weak item] _, done in
          if let item { onTap(entry, item) }
          done()
        }
      }
      self.push(CPListTemplate(title: title, sections: [CPListSection(items: items)]))
    }
  }

  private func tick(_ item: CPListItem, _ on: Bool) {
    item.setAccessoryImage(on ? UIImage(systemName: "checkmark") : nil)
  }

  private func showAddToPlaylist() {
    choices("addTargets", title: "Add to playlist") { entry, item in
      CarPlayBridge.shared.call("toggleInPlaylist", entry.id) { [weak self] added in
        self?.tick(item, added as? Bool ?? false)
      }
    }
  }

  private func showTags() {
    choices("tags", title: "Tag") { entry, item in
      CarPlayBridge.shared.call("toggleTag", entry.id) { [weak self] on in
        self?.tick(item, on as? Bool ?? false)
      }
    }
  }

  private func showDownload() {
    choices("downloadTargets", title: "Download to") { entry, _ in
      CarPlayBridge.shared.call("download", entry.id) { [weak self] message in
        guard let self, let interfaceController = self.interfaceController else { return }
        self.showNowPlaying()
        let alert = CPAlertTemplate(
          titleVariants: [message as? String ?? "Downloading"],
          actions: [
            CPAlertAction(title: "OK", style: .default) { [weak interfaceController] _ in
              interfaceController?.dismissTemplate(animated: true, completion: nil)
            }
          ])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
      }
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
