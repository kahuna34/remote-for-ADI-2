import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var analyzerCapture: AnalyzerCapture?
  private var hostPlayer: HostPlayer?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    (NSApp.delegate as? AppDelegate)?.installWindowChannel(flutterViewController, window: self)
    RegisterGeneratedPlugins(registry: flutterViewController)
    if !CommandLine.arguments.contains(where: { $0.hasPrefix("--window=") }) {
      analyzerCapture = AnalyzerCapture(messenger: flutterViewController.engine.binaryMessenger)
      hostPlayer = HostPlayer(messenger: flutterViewController.engine.binaryMessenger)
    }

    super.awakeFromNib()

    // Hintergrundprogramm: Die Flutter-Engine startet erst mit einem
    // sichtbaren Fenster. Deshalb normal öffnen und sofort wieder verstecken.
    DispatchQueue.main.async { [weak self] in
      self?.orderOut(nil)
    }
  }
}
