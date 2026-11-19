import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var analyzer: AnalyzerCapture?
  private var volumeKeys: VolumeKeys?
  private var nowPlaying: NowPlayingBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "Adi2Analyzer") {
      analyzer = AnalyzerCapture(messenger: registrar.messenger())
      volumeKeys = VolumeKeys(messenger: registrar.messenger(), analyzerUsesSession: { [weak self] in
        self?.analyzer?.usesSession == true
      })
      analyzer?.beforeSessionStart = { [weak self] in self?.volumeKeys?.yieldSession() }
      analyzer?.afterSessionStop = { [weak self] in self?.volumeKeys?.resumeSession() }
      nowPlaying = NowPlayingBridge(messenger: registrar.messenger())
    }
  }
}
