import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var windowChannel: FlutterMethodChannel?
  private var surfaceReady = false
  private var pendingReopen = false

  func installWindowChannel(_ controller: FlutterViewController, window: NSWindow) {
    let channel = FlutterMethodChannel(name: "adi2/host_window",
                                      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self, weak window] call, result in
      guard let window = window else { result(nil); return }
      switch call.method {
      case "ready":
        self?.surfaceReady = true
        if self?.pendingReopen == true {
          self?.pendingReopen = false
          self?.windowChannel?.invokeMethod("reopen", arguments: nil)
        }
        result(nil)
      case "present":
        let auxiliary = (call.arguments as? [String: Any])?["auxiliary"] as? Bool ?? false
        NSApp.setActivationPolicy(auxiliary ? .accessory : .regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        result(nil)
      case "hide":
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication,
                                             hasVisibleWindows flag: Bool) -> Bool {
    // Finder may reopen an existing bundle without launching another process.
    if surfaceReady {
      windowChannel?.invokeMethod("reopen", arguments: nil)
    } else {
      pendingReopen = true
    }
    return false
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
