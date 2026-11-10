import Foundation

/// 后端调用：所有网盘逻辑都在 Resources/quark_dl.py 里，这里只负责起进程、读输出。
enum CLI {
    static let python: String = {
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/bin/python3"
    }()

    /// 打包后：Contents/Resources/quark_dl.py；开发时：仓库里的 quark-fast/quark_dl.py
    static let script: String = {
        if let r = Bundle.main.resourcePath {
            let a = r + "/quark_dl.py"
            if FileManager.default.fileExists(atPath: a) { return a }
        }
        let dev = "/Users/pol-d/Documents/deepseek-harness/default-workspace/quark-fast/quark_dl.py"
        if FileManager.default.fileExists(atPath: dev) { return dev }
        return ""
    }()

    static let configDir = NSHomeDirectory() + "/.config/quark-fast"
    static let cookieFile = configDir + "/cookie.txt"
    static let outDir = NSHomeDirectory() + "/Downloads/quark"

    static var hasCookie: Bool {
        (try? String(contentsOfFile: cookieFile, encoding: .utf8))?.isEmpty == false
    }

    /// 逐行读取的子进程。onLine 在后台队列被调用，调用方自己切主线程。
    @discardableResult
    static func run(_ args: [String], onLine: ((String) -> Void)? = nil) -> (code: Int32, output: String) {
        guard !script.isEmpty else { return (-1, "找不到 quark_dl.py") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script] + args

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = "en_US.UTF-8"
        p.environment = env

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let collector = Collector()
        let lock = NSLock()

        let feed: (Data) -> Void = { d in
            if let text = String(data: d, encoding: .utf8) {
                lock.lock(); collector.raw += text; lock.unlock()
                for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let s = String(line)
                    if !s.isEmpty { onLine?(s) }
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { feed(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { feed(d) }
        }

        do {
            try p.run()
        } catch {
            return (-1, "启动失败：\(error.localizedDescription)")
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let text = collector.raw; lock.unlock()
        return (p.terminationStatus, text)
    }
}

private final class Collector {
    var raw = ""
}
