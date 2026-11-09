// Secure save — runs the Pare PDF browser engine (Resources/web/mp4edit.js) inside a hidden
// built-in browser, so you can time exactly what the website version would do on this Mac.
// The page is served from a tiny private web server on 127.0.0.1 (a "secure context",
// like a real https site), and the page sends the finished file back to that server.

import Foundation
import Network
import WebKit
import SwiftUI

// MARK: - Private local web server

final class LocalServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pare.localserver")
    private(set) var port: UInt16 = 0
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let webDir: URL
    var videoURL: URL?
    var uploadURL: URL?          // where the page's finished file is written

    init(webDir: URL) { self.webDir = webDir }

    var base: String { "http://127.0.0.1:\(port)/\(token)/" }

    func start() async throws {
        if listener != nil { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            l.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; cont.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let e): once.done = true; cont.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: queue)
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        readHeader(c, Data())
    }

    private func readHeader(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            var acc = acc
            if let data { acc.append(data) }
            if let r = acc.range(of: Data("\r\n\r\n".utf8)) {
                self?.respond(c, String(decoding: acc[..<r.lowerBound], as: UTF8.self), leftover: Data(acc[r.upperBound...]))
            } else if done || error != nil || acc.count > 65536 {
                c.cancel()
            } else {
                self?.readHeader(c, acc)
            }
        }
    }

    private func respond(_ c: NWConnection, _ head: String, leftover: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let prefix = "/\(token)/"
        guard parts.count >= 2, parts[1].hasPrefix(prefix) else { return send(c, 404, "text/plain", Data()) }
        let name = String(parts[1].dropFirst(prefix.count)).components(separatedBy: "?")[0]
        if parts[0] == "PUT" && name == "upload" {
            return receiveUpload(c, length: Int64(headers["content-length"] ?? "") ?? -1, leftover: leftover)
        }
        guard parts[0] == "GET" else { return send(c, 404, "text/plain", Data()) }
        let file: URL?, type: String
        switch name {
        case "secure.html": file = webDir.appendingPathComponent("secure.html"); type = "text/html; charset=utf-8"
        case "mp4edit.js": file = webDir.appendingPathComponent("mp4edit.js"); type = "text/javascript; charset=utf-8"
        case "video": file = videoURL; type = "application/octet-stream"
        default: file = nil; type = "text/plain"
        }
        guard let file, let fh = try? FileHandle(forReadingFrom: file),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        else { return send(c, 404, "text/plain", Data()) }
        defer { try? fh.close() }

        var start: Int64 = 0, end: Int64 = size - 1, partial = false
        if let range = headers["range"], range.hasPrefix("bytes=") {
            let nums = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if let a = Int64(nums.first ?? "") { start = a }
            if nums.count > 1, let b = Int64(nums[1]) { end = min(b, size - 1) }
            partial = true
        }
        guard start <= end || size == 0 else { return send(c, 416, type, Data(), extra: "Content-Range: bytes */\(size)\r\n") }
        try? fh.seek(toOffset: UInt64(start))
        let body = size == 0 ? Data() : ((try? fh.read(upToCount: Int(end - start + 1))) ?? Data())
        if partial {
            send(c, 206, type, body, extra: "Content-Range: bytes \(start)-\(start + Int64(body.count) - 1)/\(size)\r\n")
        } else {
            send(c, 200, type, body)
        }
    }

    /// Streams the finished video from the page straight to disk.
    private func receiveUpload(_ c: NWConnection, length: Int64, leftover: Data) {
        guard let out = uploadURL, length >= 0 else { return send(c, 400, "text/plain", Data()) }
        try? FileManager.default.removeItem(at: out)
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: out) else { return send(c, 500, "text/plain", Data()) }
        var got = Int64(leftover.count)
        if !leftover.isEmpty { fh.write(leftover) }
        func next() {
            if got >= length { try? fh.close(); return send(c, 200, "text/plain", Data("ok".utf8)) }
            c.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, done, error in
                if let data, !data.isEmpty { fh.write(data); got += Int64(data.count) }
                if error != nil || (done && got < length) {
                    try? fh.close(); c.cancel(); _ = self
                } else { next() }
            }
        }
        next()
    }

    private func send(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data, extra: String = "") {
        let text = [200: "OK", 206: "Partial Content", 400: "Bad Request", 404: "Not Found", 416: "Range Not Satisfiable", 500: "Error"][code] ?? "OK"
        let head = "HTTP/1.1 \(code) \(text)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Accept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        var out = Data(head.utf8); out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - Runs the browser engine

@MainActor
final class SecureSaver: NSObject {
    enum Outcome { case saved(jsMs: Int, encoder: String), failed(String), cancelled }

    let webView: WKWebView
    private let server: LocalServer?
    private var readyCont: CheckedContinuation<Bool, Never>?
    private var jobCont: CheckedContinuation<Outcome, Never>?
    private var outputURL: URL?
    private var jsMs = 0, encoder = ""
    var onProgress: ((Double) -> Void)?

    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var owner: SecureSaver?
        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            Task { @MainActor [weak owner] in owner?.received(body) }
        }
    }
    private let relay: Relay

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let uc = WKUserContentController()
        let relay = Relay()
        self.relay = relay
        uc.add(relay, name: "pare")
        cfg.userContentController = uc
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: cfg)
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: dir.appendingPathComponent("secure.html").path) {
            server = LocalServer(webDir: dir)
        } else {
            server = nil
        }
        super.init()
        relay.owner = self
    }

    func run(src: URL, crop: CGRect?, start: Double, end: Double, output: URL) async -> Outcome {
        guard let server else { return .failed("The secure engine isn't included in this build.") }
        do { try await server.start() } catch { return .failed("Couldn't start the secure engine: \(error.localizedDescription)") }
        server.videoURL = src
        server.uploadURL = output
        outputURL = output
        let size = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.intValue ?? 0

        // Fresh page each time, then hand it the job.
        let webcodecs = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            readyCont = c
            webView.load(URLRequest(url: URL(string: server.base + "secure.html")!))
        }
        guard webcodecs else { return .failed("This Mac's built-in browser doesn't support WebCodecs (needs macOS 13.3 or later).") }

        var job: [String: Any] = ["size": size, "start": start, "end": end, "name": output.lastPathComponent]
        if let r = crop { job["crop"] = ["x": Int(r.minX), "y": Int(r.minY), "w": Int(r.width), "h": Int(r.height)] }
        let json = String(data: try! JSONSerialization.data(withJSONObject: job), encoding: .utf8)!
        return await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
            jobCont = c
            webView.evaluateJavaScript("startJob(\(json)); 0", completionHandler: nil)
        }
    }

    func cancel() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        finish(.cancelled)
    }

    private func finish(_ o: Outcome) {
        if let c = readyCont { readyCont = nil; c.resume(returning: false) }
        if let c = jobCont { jobCont = nil; c.resume(returning: o) }
    }

    fileprivate func received(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "ready":
            let ok = m["webcodecs"] as? Bool ?? false
            if let c = readyCont { readyCont = nil; c.resume(returning: ok) }
        case "progress":
            if let v = m["value"] as? Double { onProgress?(v) }
        case "encoded":
            jsMs = m["ms"] as? Int ?? 0
            encoder = m["encoder"] as? String ?? ""
        case "saved":
            finish(.saved(jsMs: jsMs, encoder: encoder))
        case "error":
            finish(.failed(m["message"] as? String ?? "Unknown error"))
        default: break
        }
    }
}

/// Keeps the hidden browser inside the window, so macOS doesn't slow it down as "not visible".
struct SecureHost: NSViewRepresentable {
    let saver: SecureSaver
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        saver.webView.frame = v.bounds
        v.addSubview(saver.webView)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
