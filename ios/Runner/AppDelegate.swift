import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var progressFolder: ProgressFolderBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    progressFolder = ProgressFolderBridge(messenger: messenger)
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

/// User-selected File Provider folder, not an app-owned iCloud container.
/// Works through document-picker grants without CloudKit entitlements.
private final class ProgressFolderBridge: NSObject, UIDocumentPickerDelegate {
  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "kira.progress-folder")
  private var pendingPicker: FlutterResult?
  private let bookmarkKey = "kira.progress-folder.bookmark.v1"
  private let identityKey = "kira.progress-folder.identity.v1"
  private let filePattern = "^kira-progress-[a-f0-9]{32}\\.json$"
  private let limit = 8 * 1024 * 1024

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let channel = FlutterMethodChannel(
      name: "io.github.reabin.kira/progress_folder", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "status":
        result([
          "configured": self.defaults.data(forKey: self.bookmarkKey) != nil,
          "installation": UIDevice.current.identifierForVendor?.uuidString ?? "",
          "identity": self.defaults.string(forKey: self.identityKey) ?? ""
        ])
      case "choose": self.choose(result)
      case "read", "write":
        // File Provider coordination can wait for downloads; never block UIKit.
        self.queue.async {
          do {
            let url = try self.folder()
            guard url.startAccessingSecurityScopedResource() else {
              throw self.failure("同步文件夹授权已失效，请重新选择文件夹")
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let value: Any?
            if call.method == "read" {
              value = try self.read(url)
            } else {
              guard let args = call.arguments as? [String: Any],
                    let device = args["device"] as? String,
                    device.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
                    let text = args["document"] as? String,
                    let data = text.data(using: .utf8), data.count <= self.limit else {
                throw self.failure("无效的阅读进度文件")
              }
              try self.write(url.appendingPathComponent("kira-progress-\(device).json"), data)
              value = nil
            }
            DispatchQueue.main.async { result(value) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "progress_folder", message: error.localizedDescription, details: nil))
            }
          }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func failure(_ message: String) -> NSError {
    NSError(domain: "KiraProgress", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func folder() throws -> URL {
    guard let data = defaults.data(forKey: bookmarkKey) else {
      throw failure("请先选择 iCloud Drive 同步文件夹")
    }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    if stale {
      guard url.startAccessingSecurityScopedResource() else {
        throw failure("同步文件夹授权已失效，请重新选择文件夹")
      }
      defer { url.stopAccessingSecurityScopedResource() }
      defaults.set(try url.bookmarkData(options: .minimalBookmark,
        includingResourceValuesForKeys: nil, relativeTo: nil), forKey: bookmarkKey)
    }
    return url
  }

  private func choose(_ result: @escaping FlutterResult) {
    guard pendingPicker == nil else {
      result(FlutterError(code: "busy", message: "文件夹选择器已打开", details: nil))
      return
    }
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }
    guard var presenter = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "no_window", message: "当前无法打开文件夹选择器", details: nil))
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    pendingPicker = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPicker?(false)
    pendingPicker = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]) {
    let result = pendingPicker
    pendingPicker = nil
    do {
      guard let url = urls.first, url.startAccessingSecurityScopedResource() else {
        throw failure("未取得同步文件夹的读写权限")
      }
      defer { url.stopAccessingSecurityScopedResource() }
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey])
      guard values.isDirectory == true else { throw failure("请选择文件夹") }
      // The picker also exposes other providers. Require iCloud here so a local
      // 'On My iPad' folder cannot be mistaken for cross-device synchronization.
      guard values.isUbiquitousItem == true else {
        throw failure("请选择 iCloud Drive 中的文件夹，而不是本机文件夹")
      }
      let data = try url.bookmarkData(options: .minimalBookmark,
        includingResourceValuesForKeys: nil, relativeTo: nil)
      defaults.set(data, forKey: bookmarkKey)
      defaults.set(UUID().uuidString, forKey: identityKey)
      result?(true)
    } catch {
      result?(FlutterError(code: "progress_folder", message: error.localizedDescription, details: nil))
    }
  }

  private func read(_ root: URL) throws -> [String: String] {
    let manager = FileManager.default
    var error: NSError?
    var failure: Error?
    var result = [String: String]()
    var files = [URL]()
    let coordinator = NSFileCoordinator(filePresenter: nil)
    coordinator.coordinate(readingItemAt: root, options: [], error: &error) { directory in
      do {
        files = try manager.contentsOfDirectory(at: directory,
          includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
          .filter { $0.lastPathComponent.range(of: self.filePattern, options: .regularExpression) != nil }
      } catch { failure = error }
    }
    if let error = error { throw error }
    if let failure = failure { throw failure }
    guard files.count <= 100 else { throw self.failure("同步设备文件超过 100 个") }
    var total = 0
    // Release the directory coordination before coordinating individual files;
    // nested coordination can deadlock some File Provider implementations.
    for file in files {
      // Coordination materializes cloud-only content. Unavailable content is
      // an error, never interpreted as an empty remote library.
      var fileError: NSError?
      NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: file,
        options: [], error: &fileError) { materialized in
          do {
            let values = try materialized.resourceValues(forKeys:
              [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
              throw self.failure("同步内容必须是普通文件，不能是链接")
            }
            guard (values.fileSize ?? 0) <= self.limit else {
              throw self.failure("阅读进度文件超过 8 MB")
            }
            let data = try Data(contentsOf: materialized)
            total += data.count
            guard data.count <= self.limit, total <= 16 * 1024 * 1024,
                  let text = String(data: data, encoding: .utf8) else {
              throw self.failure("阅读进度文件过大或格式无效")
            }
            result[file.lastPathComponent] = text
          } catch { failure = error }
        }
      if let fileError = fileError { throw fileError }
      if let failure = failure { throw failure }
    }
    return result
  }

  private func write(_ file: URL, _ data: Data) throws {
    var error: NSError?
    var failure: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file,
      options: .forReplacing, error: &error) { target in
        do {
          if FileManager.default.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw self.failure("同步文件不能是链接") }
          }
          try data.write(to: target, options: .atomic)
        } catch { failure = error }
      }
    if let error = error { throw error }
    if let failure = failure { throw failure }
  }
}
