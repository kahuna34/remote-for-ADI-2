import Cocoa
import FlutterMacOS

/// Public Apple Events only. Never starts a player or downloads Spotify covers.
final class HostPlayer {
  private let channel: FlutterMethodChannel
  private let queue = DispatchQueue(label: "adi2.host.player")
  private var selected: String?
  private var artworkKey = ""
  private var artwork: String?
  private let players = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")]

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "adi2/host_player", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      self.queue.async {
        let response: Any
        if call.method == "state" {
          response = self.state()
        } else if call.method == "command", let command = call.arguments as? String {
          self.command(command)
          response = NSNull()
        } else {
          DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
          return
        }
        DispatchQueue.main.async { result(response) }
      }
    }
  }

  private func script(_ source: String) -> NSAppleEventDescriptor? {
    var error: NSDictionary?
    let value = NSAppleScript(source: "with timeout of 2 seconds\n\(source)\nend timeout")?
      .executeAndReturnError(&error)
    return error == nil ? value : nil
  }

  private func running(_ id: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
  }

  private func state() -> [String: Any] {
    var candidates: [(String, String, NSAppleEventDescriptor)] = []
    for (id, name) in players where running(id) {
      if let value = script("""
        tell application id "\(id)"
          if player state is stopped then return {"", "", "stopped", ""}
          return {name of current track, artist of current track, player state as string, id of current track as string}
        end tell
        """) {
        candidates.append((id, name, value))
      }
    }
    guard let candidate = candidates.first(where: { $0.2.atIndex(3)?.stringValue == "playing" })
        ?? candidates.first(where: { $0.0 == selected }) ?? candidates.first else {
      selected = nil
      artworkKey = ""
      artwork = nil
      return ["playing": false, "artwork": NSNull()]
    }
    let (id, app, value) = candidate
    selected = id
    let title = value.atIndex(1)?.stringValue ?? ""
    let track = value.atIndex(4)?.stringValue ?? ""
    let key = "\(id):\(track):\(title)"
    if key != artworkKey {
      artworkKey = key
      artwork = nil
      // Music embeds local artwork. Spotify exposes an HTTPS URL only; do not fetch it.
      if id == "com.apple.Music", !title.isEmpty,
         let data = script("tell application id \"com.apple.Music\" to return raw data of artwork 1 of current track")?.data,
         data.count <= 8_000_000, let image = NSImage(data: data) {
        let size = NSSize(width: 160, height: 160)
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        thumbnail.unlockFocus()
        if let tiff = thumbnail.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]),
           jpeg.count <= 30_000 {
          artwork = jpeg.base64EncodedString()
        }
      }
    }
    return ["title": String(title.prefix(1024)),
            "artist": String((value.atIndex(2)?.stringValue ?? "").prefix(1024)),
            "app": app, "playing": value.atIndex(3)?.stringValue == "playing",
            "artwork": artwork as Any? ?? NSNull()]
  }

  private func command(_ command: String) {
    let actions = ["play": "play", "pause": "pause", "toggle": "playpause",
                   "next": "next track", "previous": "previous track"]
    guard let action = actions[command] else { return }
    if selected == nil { _ = state() }
    guard let id = selected, running(id) else { return }
    _ = script("tell application id \"\(id)\" to \(action)")
  }
}
