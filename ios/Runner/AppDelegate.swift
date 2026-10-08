import Flutter
import UIKit
import AVFoundation
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var readerVolume: IOSReaderVolumeController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    readerVolume = IOSReaderVolumeController(messenger: messenger)
    let channel = FlutterMethodChannel(
      name: "io.github.caolib.kira/app_icon",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "setAppIcon":
        let index = call.arguments as? [String: Any]
        let idx = index?["index"] as? Int ?? 0
        let iconName: String? = idx == 0 ? nil : "AppIcon-1"
        UIApplication.shared.setAlternateIconName(iconName) { error in
          if let error = error {
            result(FlutterError(code: "icon_error", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      case "getAppIconIndex":
        let current = UIApplication.shared.alternateIconName
        result(current == nil ? 0 : 1)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// iOS exposes output-volume changes rather than hardware key events.
/// Keep this session strictly scoped to a foreground, uncovered reader.
private final class IOSReaderVolumeController {
  private let channel: FlutterMethodChannel
  private let session = AVAudioSession.sharedInstance()
  private var volumePoll: Timer?
  private var observation: NSKeyValueObservation?
  private var notifications: [NSObjectProtocol] = []
  private var volumeView: MPVolumeView?
  private var slider: UISlider?
  private var wanted = false
  private var interrupted = false
  private var active = false
  private var generation = 0
  private var originalVolume: Float?
  private var baseline: Float = 0.5
  private var suppress = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "io.github.caolib.kira/ios_reader_volume", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "enable":
        self.wanted = true
        do { try self.start(); result(nil) }
        catch {
          self.stop()
          result(FlutterError(code: "volume_session", message: error.localizedDescription, details: nil))
        }
      case "disable":
        self.wanted = false
        self.stop()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    watch(UIApplication.willResignActiveNotification) { $0.stop() }
    watch(UIApplication.didBecomeActiveNotification) { $0.resume() }
    watch(AVAudioSession.interruptionNotification) { controller, note in
      let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      if value == AVAudioSession.InterruptionType.began.rawValue {
        controller.interrupted = true
        controller.stop()
      } else if value == AVAudioSession.InterruptionType.ended.rawValue {
        controller.interrupted = false
        controller.resume()
      }
    }
    watch(AVAudioSession.mediaServicesWereResetNotification) { controller in
      controller.stop()
      controller.resume()
    }
  }

  private func watch(_ name: Notification.Name, action: @escaping (IOSReaderVolumeController) -> Void) {
    watch(name) { controller, _ in action(controller) }
  }

  private func watch(_ name: Notification.Name,
                     action: @escaping (IOSReaderVolumeController, Notification) -> Void) {
    notifications.append(NotificationCenter.default.addObserver(
      forName: name, object: nil, queue: .main) { [weak self] note in
        guard let self = self else { return }
        action(self, note)
      })
  }

  private func resume() {
    guard wanted, !interrupted, UIApplication.shared.applicationState == .active else { return }
    do { try start() } catch { stop() }
  }

  private func start() throws {
    guard wanted, !interrupted, UIApplication.shared.applicationState == .active else { return }
    // Native lifecycle notifications tear down the old session before resume.
    if active { return }
    stop()
    try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    try session.setActive(true)
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }) else {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw NSError(domain: "ReaderVolume", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No active reader window"])
    }
    let view = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 40))
    view.showsRouteButton = false
    window.addSubview(view)
    view.layoutIfNeeded()
    guard let control = view.subviews.compactMap({ $0 as? UISlider }).first else {
      view.removeFromSuperview()
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw NSError(domain: "ReaderVolume", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Volume control unavailable"])
    }
    volumeView = view
    slider = control
    originalVolume = session.outputVolume
    baseline = min(0.9, max(0.1, session.outputVolume))
    active = true
    suppress = true
    let token = generation
    observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
      guard let self = self, let new = change.newValue else { return }
      DispatchQueue.main.async {
        self.handleVolume(new, token: token)
      }
    }
    // Some iOS versions cache outputVolume across session reactivation.
    // MPVolumeView's live slider is a second public control-based signal.
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      guard let self = self, let slider = self.slider else { return }
      self.handleVolume(slider.value, token: token)
    }
    volumePoll = timer
    RunLoop.main.add(timer, forMode: .common)
    // The system control needs a run-loop turn before it can set volume.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      guard let self = self, self.generation == token, self.active else { return }
      self.resetVolume(token: token)
    }
  }

  private func handleVolume(_ value: Float, token: Int) {
    guard active, generation == token, !suppress,
          UIApplication.shared.applicationState == .active,
          abs(value - baseline) > 0.001 else { return }
    // A reset back to baseline is our own write, never a reverse page turn.
    channel.invokeMethod(value > baseline ? "volumeUp" : "volumeDown", arguments: nil)
    resetVolume(token: token)
  }

  private func resetVolume(token: Int) {
    guard active, generation == token, let slider = slider else { return }
    suppress = true
    slider.setValue(baseline, animated: false)
    slider.sendActions(for: .valueChanged)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      guard let self = self, self.generation == token, self.active else { return }
      self.suppress = false
    }
  }

  private func stop() {
    let wasActive = active
    generation += 1
    volumePoll?.invalidate()
    volumePoll = nil
    observation?.invalidate()
    observation = nil
    active = false
    suppress = false
    if let original = originalVolume, let slider = slider {
      slider.setValue(original, animated: false)
      slider.sendActions(for: .valueChanged)
    }
    originalVolume = nil
    slider = nil
    volumeView?.removeFromSuperview()
    volumeView = nil
    if wasActive {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  deinit {
    volumePoll?.invalidate()
    notifications.forEach { NotificationCenter.default.removeObserver($0) }
    observation?.invalidate()
  }
}
