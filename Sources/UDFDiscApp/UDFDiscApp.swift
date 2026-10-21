import AppKit
import SwiftUI
import UDFKit

enum AppName {
    /// Shown in the menu bar, the window and the Finder (the bundle uses the same name).
    static var display: String { L("光盘通", "DiscLink") }
}

@main
struct UDFDiscApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window(AppName.display, id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 440)
                .onAppear {
                    delegate.model = model
                    // `UDFDiscApp <image>` opens an image straight away (handy for testing).
                    let images = CommandLine.arguments.dropFirst().filter {
                        !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)   // skip values like -AppleLanguages (en)
                    }
                    model.didLaunch(openingImage: !images.isEmpty)
                    for arg in images { model.addImage(URL(fileURLWithPath: arg)) }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("打开镜像…", "Open Disc Image…")) { model.openImagePanel() }.keyboardShortcut("o")
                Button(L("推出光盘", "Eject Disc")) {
                    if let d = model.currentDrive { Task { await model.eject(d) } }
                }
                .keyboardShortcut("e")
                .disabled(model.currentDrive == nil || model.busy != nil)
                Button(L("关闭光盘", "Close Disc")) { Task { await model.closeSource() } }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.source == nil || model.busy != nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Built as a plain executable, so make sure it behaves like a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Give the drive back to macOS before quitting.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.closeSynchronously() }
    }
}
