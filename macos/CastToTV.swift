import AppKit
import Foundation

/// Unsandboxed `casttv://` handler. Safari Services only `open` a URL;
/// this app decodes it and runs `~/.local/bin/cast.sh`.
///
///   casttv://play?u=<base64url>     play now
///   casttv://queue?u=<base64url>    play after the current video
///   casttv://<base64>               play now (legacy)
///   casttv://queue/<base64>         queue (legacy)
@main
enum CastToTVMain {
    static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var handled = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(fourCC("GURL")),
            andEventID: AEEventID(fourCC("GURL"))
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.handled else { return }
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(handleURL)
    }

    @objc func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard
            let raw = event.paramDescriptor(forKeyword: AEKeyword(fourCC("----")))?.stringValue,
            let url = URL(string: raw)
        else { return }
        handleURL(url)
    }

    private func handleURL(_ url: URL) {
        if handled { return }
        handled = true
        CastRunner.run(url: url)
        NSApp.terminate(nil)
    }
}

enum CastRunner {
    static func run(url: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logDir = home.appendingPathComponent(".local/share")
        let logURL = logDir.appendingPathComponent("cast.log")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        func append(_ text: String) {
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }

        let parsed = parseCastURL(url)
        append("=== \(timestamp()) ===\nraw: \(url.absoluteString)\n")

        guard let parsed else {
            append("failed to parse casttv URL\nexit=1\n")
            return
        }
        guard let youtube = decodePayload(parsed.payload), !youtube.isEmpty else {
            append("failed to decode payload: \(parsed.payload)\nexit=1\n")
            return
        }

        let modeFlag = parsed.queue ? " --queue" : ""
        append("decoded: \(youtube) modeFlag=\(modeFlag)\n")

        let script = home.appendingPathComponent(".local/bin/cast.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            append("missing executable \(script.path)\nexit=1\n")
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        _ = try? handle.seekToEnd()

        let proc = Process()
        proc.executableURL = script
        proc.arguments = parsed.queue ? ["--queue", youtube] : [youtube]
        proc.standardOutput = handle
        proc.standardError = handle
        var env = ProcessInfo.processInfo.environment
        env["PATH"] =
            "\(home.path)/Miniforge3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        do {
            try proc.run()
            proc.waitUntilExit()
            append("exit=\(proc.terminationStatus)\n")
        } catch {
            append("failed to run cast.sh: \(error)\nexit=1\n")
        }
        try? handle.close()
    }
}

struct ParsedCastURL {
    var queue: Bool
    var payload: String
}

func parseCastURL(_ url: URL) -> ParsedCastURL? {
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let host = (comps?.host ?? "").lowercased()
    let path = comps?.path ?? ""
    let queryU = comps?.queryItems?.first(where: { $0.name == "u" })?.value

    if host == "play" || host == "queue" {
        let payload = queryU ?? path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if payload.isEmpty { return nil }
        return ParsedCastURL(queue: host == "queue", payload: payload)
    }

    // Legacy: casttv://<base64> or casttv://queue/<base64>
    var rest = url.absoluteString
    let prefix = "casttv://"
    if rest.lowercased().hasPrefix(prefix) {
        rest = String(rest.dropFirst(prefix.count))
    }
    if rest.isEmpty { return nil }
    if rest.lowercased().hasPrefix("queue/") {
        return ParsedCastURL(queue: true, payload: String(rest.dropFirst(6)))
    }
    if rest.lowercased().hasPrefix("play/") {
        return ParsedCastURL(queue: false, payload: String(rest.dropFirst(5)))
    }
    return ParsedCastURL(queue: false, payload: rest)
}

func decodePayload(_ payload: String) -> String? {
    var s = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let pad = (4 - s.count % 4) % 4
    s += String(repeating: "=", count: pad)
    guard let data = Data(base64Encoded: s) else { return nil }
    return String(data: data, encoding: .utf8)
}

func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
}

func fourCC(_ s: String) -> OSType {
    var n: UInt32 = 0
    for b in s.utf8.prefix(4) {
        n = (n << 8) | UInt32(b)
    }
    return OSType(n)
}
