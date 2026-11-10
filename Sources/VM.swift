import Foundation
import AppKit
import Combine

struct QItem: Identifiable, Decodable {
    let fid: String
    let name: String
    let size: Int64
    let dir: Bool
    var id: String { fid }
}

struct LsResp: Decodable {
    let path: String
    let items: [QItem]
}

enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/QuarkFast.log")
    static func w(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

func humanSize(_ n: Int64) -> String {
    if n <= 0 { return "-" }
    var v = Double(n)
    for u in ["B", "KB", "MB", "GB", "TB"] {
        if v < 1024 { return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, u) }
        v /= 1024
    }
    return String(format: "%.1f PB", v)
}

func joinPath(_ base: String, _ name: String) -> String {
    if base == "/" || base.isEmpty { return "/" + name }
    return base + "/" + name
}

func parentPath(_ p: String) -> String {
    let parts = p.split(separator: "/").map(String.init)
    if parts.count <= 1 { return "/" }
    return "/" + parts.dropLast().joined(separator: "/")
}

final class VM: ObservableObject {
    @Published var items: [QItem] = []
    @Published var path = "/"
    @Published var loading = false
    @Published var err: String?
    @Published var threads = 512

    @Published var downloading = false
    @Published var finishedName: String?
    @Published var downloaded: Int64 = 0
    @Published var total: Int64 = 0
    @Published var speedText = ""
    @Published var etaText = ""
    @Published var currentName = ""
    @Published var logText = ""

    private var proc: Process?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(downloaded) / Double(total))
    }

    // MARK: - 列表

    func refresh() {
        loading = true
        err = nil
        let target = path
        DispatchQueue.global().async {
            let r = CLI.run(["ls", target, "--json"])
            DispatchQueue.main.async {
                self.loading = false
                let line = r.output
                    .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .first(where: { $0.contains("\"items\"") })
                guard let line, let data = line.data(using: .utf8),
                      let obj = try? JSONDecoder().decode(LsResp.self, from: data) else {
                    let msg = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    Log.w("ls \(target) 失败 code=\(r.code) out=\(msg.suffix(200))")
                    self.err = msg.isEmpty ? "读取失败（退出码 \(r.code)）" : String(msg.suffix(300))
                    return
                }
                Log.w("ls \(target) -> \(obj.items.count) 项")
                self.items = obj.items.sorted { a, b in
                    if a.dir != b.dir { return a.dir }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
        }
    }

    func enter(_ item: QItem) {
        guard item.dir else { return }
        path = joinPath(path, item.name)
        refresh()
    }

    func up() {
        path = parentPath(path)
        refresh()
    }

    func openDownloads() {
        try? FileManager.default.createDirectory(atPath: CLI.outDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: CLI.outDir))
    }

    // MARK: - 下载

    func download(_ item: QItem) {
        guard !downloading else { return }
        guard CLI.hasCookie else {
            err = "还没有登录态，先在终端跑：python3 quark-fast/login.py"
            return
        }
        let spec = joinPath(path, item.name)
        startDownload(spec: spec, name: item.name, size: item.size)
    }

    private func startDownload(spec: String, name: String, size: Int64) {
        downloading = true
        finishedName = nil
        err = nil
        currentName = name
        downloaded = 0
        total = size
        speedText = "连接中…"
        etaText = ""
        logText = ""

        let p = Process()
        p.executableURL = URL(fileURLWithPath: CLI.python)
        p.arguments = [CLI.script, "dl", spec, "-j", String(threads)]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["LANG"] = "en_US.UTF-8"
        p.environment = env

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out

        let buf = LineBuffer { line in
            self.consume(line)
        }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { buf.feed(d) }
        }
        p.terminationHandler = { pr in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.downloading = false
                self.speedText = ""
                self.etaText = ""
                if pr.terminationStatus == 0 {
                    self.finishedName = name
                    self.downloaded = self.total
                } else {
                    self.err = "下载中断（退出码 \(pr.terminationStatus)）。重新点一次会断点续传。"
                }
            }
        }

        Log.w("dl 开始 spec=\(spec) threads=\(threads)")
        proc = p
        do {
            try p.run()
        } catch {
            downloading = false
            err = "启动失败：\(error.localizedDescription)"
        }
    }

    func cancel() {
        proc?.terminate()
        proc = nil
    }

    /// 解析 aria2 的进度行：[#abc 31MiB/6.5GiB(0%) CN:512 DL:3.3MiB ETA:32m50s]
    private func consume(_ line: String) {
        if line.contains("DL:") || line.contains("ETA:") {
            let nums = Self.parse(line)
            DispatchQueue.main.async {
                if let done = nums.done { self.downloaded = done }
                if let all = nums.total, all > 0 { self.total = all }
                if let sp = nums.speed { self.speedText = sp + "/s" }
                if let e = nums.eta { self.etaText = "剩余 " + e }
            }
            return
        }
        if line.hasPrefix("==") || line.contains("✓") || line.contains("✗") || line.contains("错误") {
            DispatchQueue.main.async { self.logText = line }
        }
    }

    private static func parse(_ s: String) -> (done: Int64?, total: Int64?, speed: String?, eta: String?) {
        var done: Int64?; var total: Int64?; var speed: String?; var eta: String?
        // 31MiB/6.5GiB
        if let r = s.range(of: #"([0-9.]+)([KMGTP]?i?B)/([0-9.]+)([KMGTP]?i?B)"#, options: .regularExpression) {
            let flat = String(s[r])
            let parts = flat.split(separator: "/")
            if parts.count == 2 {
                done = bytes(String(parts[0]))
                total = bytes(String(parts[1]))
            }
        }
        if let r = s.range(of: #"DL:([0-9.]+)([KMGTP]?i?B)"#, options: .regularExpression) {
            let t = String(s[r]).replacingOccurrences(of: "DL:", with: "")
            speed = t
        }
        if let r = s.range(of: #"ETA:([0-9]+[hms][0-9a-z]*)"#, options: .regularExpression) {
            eta = String(s[r]).replacingOccurrences(of: "ETA:", with: "")
        }
        return (done, total, speed, eta)
    }

    private static func bytes(_ s: String) -> Int64 {
        let units: [(String, Double)] = [("GiB", 1073741824.0), ("MiB", 1048576.0), ("KiB", 1024.0),
                                         ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1.0)]
        let t = s.trimmingCharacters(in: .whitespaces)
        for (u, m) in units where t.hasSuffix(u) {
            let num = Double(t.dropLast(u.count)) ?? 0
            return Int64(num * m)
        }
        return Int64(Double(t) ?? 0)
    }
}

/// 把 Pipe 的字节流切成行（aria2 用 \r 刷新，两种都切）
final class LineBuffer {
    private var data = Data()
    private let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }

    func feed(_ d: Data) {
        data.append(d)
        while let idx = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let slice = data[data.startIndex..<idx]
            data = Data(data[data.index(after: idx)...])
            if let s = String(data: slice, encoding: .utf8), !s.isEmpty {
                handler(s)
            }
        }
        if data.count > 1 << 20 { data = Data() }
    }
}
