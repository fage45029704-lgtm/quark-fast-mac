import SwiftUI
import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let vm = VM()

    func applicationDidFinishLaunching(_ n: Notification) {
        let view = ContentView().environmentObject(vm)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "QuarkFast · 夸克快下"
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(width: 820, height: 520)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let auto = ProcessInfo.processInfo.environment["QF_AUTODL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let it = self.vm.items.first(where: { $0.name == auto }) {
                    Log.w("AUTODL \(auto)")
                    self.vm.download(it)
                }
            }
        }

        // 自检用：QF_SHOT=/tmp/x.png 启动即把窗口本身渲染成 PNG（不需要屏幕录制权限）
        if let shot = ProcessInfo.processInfo.environment["QF_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                let wid = CGWindowID(self.window.windowNumber)
                if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                                    [.boundsIgnoreFraming, .bestResolution]) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    if let d = rep.representation(using: .png, properties: [:]) {
                        try? d.write(to: URL(fileURLWithPath: shot))
                    }
                }
                if ProcessInfo.processInfo.environment["QF_EXIT"] != nil { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
