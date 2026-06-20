import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Native security-scoped file access bridge (sandbox-correct file/folder
    // picking + persistent bookmarks). Channel: `autosub/secure_files`.
    SecureFilesPlugin.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
