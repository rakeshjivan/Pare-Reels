// Pare Reels — a dead-simple video downloader for macOS.
// Paste one or more links, pick a quality, press Download.
// Uses yt-dlp (+ deno + ffmpeg), which the app fetches itself on first launch.

import SwiftUI
import AppKit

// MARK: - App

@main
struct PareReelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = DownloadModel()

    var body: some Scene {
        WindowGroup("Pare Reels") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 580, minHeight: 560)
                .task { await model.setup() }
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Quality

enum Quality: String, CaseIterable, Identifiable {
    case best = "Best available"
    case p2160 = "4K (2160p)"
    case p1440 = "1440p"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"
    case audio = "Audio only (MP3)"

    var id: String { rawValue }

    var height: Int? {
        switch self {
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        default: return nil
        }
    }
}

// MARK: - Logins (stage 2)

/// Borrow the login from a browser the user is already signed in with.
enum BrowserLogin: String, CaseIterable, Identifiable {
    case none = "Don't use"
    case safari = "Safari"
    case chrome = "Chrome"
    case firefox = "Firefox"
    case edge = "Edge"
    case brave = "Brave"
    case vivaldi = "Vivaldi"
    case opera = "Opera"
    case chromium = "Chromium"

    var id: String { rawValue }
    var ytdlpName: String? { self == .none ? nil : rawValue.lowercased() }
}

/// Per-video credentials typed in when a download asks for them. Kept in memory only.
struct Credentials {
    var videoPassword = ""
    var username = ""
    var password = ""
}

// MARK: - Download item

enum ItemStatus: Equatable {
    case waiting, downloading, processing, done, failed, cancelled

    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .downloading: return "Downloading"
        case .processing: return "Finishing up"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isFinal: Bool { self == .done || self == .failed || self == .cancelled }
}

struct DownloadItem: Identifiable {
    let id = UUID()
    let url: String
    var title: String?
    var progress: Double = 0
    var status: ItemStatus = .waiting
    var detail: String = ""
    var needsAuth = false
    var credentials = Credentials()
    var needsFinder = false
    var direct: DirectJob?
}

// MARK: - Tools (yt-dlp, deno, ffmpeg)

enum Tools {
    static let dir: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pare Reels/bin", isDirectory: true)

    static var ytdlp: URL { dir.appendingPathComponent("yt-dlp") }
    static var deno: URL { dir.appendingPathComponent("deno") }

    #if arch(arm64)
    static let denoZip = "https://github.com/denoland/deno/releases/latest/download/deno-aarch64-apple-darwin.zip"
    static let ffArch = "arm64"
    #else
    static let denoZip = "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-apple-darwin.zip"
    static let ffArch = "amd64"
    #endif

    static let ytdlpURL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    static func ffmpegZip(_ program: String) -> String {
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(ffArch)/release/\(program).zip"
    }

    static let searchPath = [dir.path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func find(_ name: String) -> URL? {
        for d in searchPath {
            let p = URL(fileURLWithPath: d).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p.path) { return p }
        }
        return nil
    }

    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = searchPath.joined(separator: ":")
        return e
    }

    static func download(_ remote: String, to dest: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: URL(string: remote)!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "PareReels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Server returned an error for \(remote)"])
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    /// Downloads a zip, extracts it and installs the named binary into `dir`.
    static func installFromZip(_ remote: String, binary: String) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("a.zip")
        try await download(remote, to: zip)
        let out = work.appendingPathComponent("x")
        _ = try runQuick("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard let found = fm.enumerator(at: out, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == binary }) else {
            throw NSError(domain: "PareReels", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(binary) not found in download"])
        }
        let dest = dir.appendingPathComponent(binary)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: found, to: dest)
        makeRunnable(dest)
    }

    static func makeRunnable(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        _ = try? runQuick("/usr/bin/xattr", ["-d", "com.apple.quarantine", url.path])
    }

    /// Runs a tool off the main thread and returns its exit code and standard output.
    static func capture(_ exe: String, _ args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { (c: CheckedContinuation<(Int32, String), Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { c.resume(returning: (-1, "")); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                c.resume(returning: (p.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
        }
    }

    @discardableResult
    static func runQuick(_ exe: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - Line-by-line process output

final class LineSplitter {
    private var buffer = Data()
    private let onLine: (String) -> Void
    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        buffer.append(data)
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<i]
            buffer.removeSubrange(buffer.startIndex...i)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { onLine(s) }
        }
    }

    func flush() {
        if let s = String(data: buffer, encoding: .utf8), !s.isEmpty { onLine(s) }
        buffer.removeAll()
    }
}

// MARK: - Model

@MainActor
final class DownloadModel: ObservableObject {
    @Published var urlText = ""
    @Published var quality: Quality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "folder") }
    }
    @Published var browser: BrowserLogin {
        didSet { UserDefaults.standard.set(browser.rawValue, forKey: "browser") }
    }
    @Published var authItemID: UUID?          // drives the "needs a password" sheet
    @Published var finderTarget: FinderTarget? // drives the "find the video on the page" window
    @Published var needsFullDiskAccess = false
    @Published var items: [DownloadItem] = []
    @Published var isRunning = false
    @Published var ready = false
    @Published var setupMessage: String? = "Getting things ready…"
    @Published var setupFailed = false
    @Published var ffmpeg: URL?
    @Published var log = ""
    @Published var notice: String?

    private var current: Process?
    private var cancelRequested = false
    private var lastErrors: [Int: String] = [:]
    private var lastFiles: [Int: String] = [:]

    /// Sites the downloader can't read, so we go straight to finding the file on the page.
    static let finderHosts = ["gotowebinar.com", "goto.com", "gotomeeting.com", "gotostage.com", "gotowebinar.cn"]

    static func needsFinder(_ link: String) -> Bool {
        guard let host = URL(string: link)?.host?.lowercased() else { return false }
        return finderHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    init() {
        let d = UserDefaults.standard
        quality = Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .p1080
        browser = BrowserLogin(rawValue: d.string(forKey: "browser") ?? "") ?? .none
        if let p = d.string(forKey: "folder"), FileManager.default.fileExists(atPath: p) {
            folder = URL(fileURLWithPath: p, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
    }

    // First-launch setup: fetch yt-dlp, deno and ffmpeg if missing; keep yt-dlp current.
    func setup() async {
        setupFailed = false
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Tools.dir, withIntermediateDirectories: true)

            if fm.isExecutableFile(atPath: Tools.ytdlp.path) {
                setupMessage = "Checking for updates…"
                await updateYtdlp()
            } else {
                setupMessage = "Downloading yt-dlp (first launch only)…"
                try await Tools.download(Tools.ytdlpURL, to: Tools.ytdlp)
                Tools.makeRunnable(Tools.ytdlp)
            }

            if Tools.find("deno") == nil {
                setupMessage = "Downloading Deno (needed for YouTube)…"
                do { try await Tools.installFromZip(Tools.denoZip, binary: "deno") }
                catch { appendLog("Deno download failed: \(error.localizedDescription)") }
            }

            if Tools.find("ffmpeg") == nil || Tools.find("ffprobe") == nil {
                setupMessage = "Downloading ffmpeg (needed for HD and MP3)…"
                do {
                    if Tools.find("ffmpeg") == nil { try await Tools.installFromZip(Tools.ffmpegZip("ffmpeg"), binary: "ffmpeg") }
                    if Tools.find("ffprobe") == nil { try await Tools.installFromZip(Tools.ffmpegZip("ffprobe"), binary: "ffprobe") }
                } catch {
                    appendLog("ffmpeg download failed: \(error.localizedDescription)")
                }
            }
            ffmpeg = Tools.find("ffmpeg")
            ready = true
            setupMessage = nil
        } catch {
            setupFailed = true
            setupMessage = "Setup failed: \(error.localizedDescription). Check your internet connection."
        }
    }

    private func updateYtdlp() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = try? Tools.runQuick(Tools.ytdlp.path, ["-U"])
                c.resume()
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func start() {
        let urls = urlText
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasPrefix("http") }
            .map(Self.unwrap)
        guard !urls.isEmpty else {
            notice = "Paste at least one link starting with http."
            return
        }
        notice = nil
        needsFullDiskAccess = false
        items = urls.map { DownloadItem(url: $0) }
        isRunning = true
        cancelRequested = false
        Task {
            for i in items.indices {
                if cancelRequested { items[i].status = .cancelled; continue }
                if Self.needsFinder(items[i].url) {
                    items[i].needsFinder = true
                    items[i].detail = "Finding the video on the page…"
                    continue
                }
                await download(index: i)
            }
            isRunning = false
            current = nil
            promptNext()
        }
    }

    /// Unwraps Outlook "Safe Links" (…safelinks.protection.outlook.com/?url=…) to the real address.
    static func unwrap(_ link: String) -> String {
        guard let comps = URLComponents(string: link),
              let host = comps.host?.lowercased(), host.hasSuffix("safelinks.protection.outlook.com"),
              let inner = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              inner.lowercased().hasPrefix("http") else { return link }
        return inner
    }

    /// Re-run one item with the credentials typed into the sheet.
    func retry(itemID: UUID, with creds: Credentials) {
        guard let i = items.firstIndex(where: { $0.id == itemID }), !isRunning else { return }
        items[i].credentials = creds
        items[i].needsAuth = false
        items[i].progress = 0
        items[i].status = .waiting
        isRunning = true
        cancelRequested = false
        Task {
            await download(index: i)
            isRunning = false
            current = nil
            promptNext()
        }
    }

    /// After a run: open the video finder for the next page that needs it, otherwise ask for a password.
    private func promptNext() {
        if let f = items.first(where: { $0.needsFinder }), let url = URL(string: f.url) {
            finderTarget = FinderTarget(id: f.id, url: url)
        } else if let first = items.first(where: { $0.needsAuth }) {
            authItemID = first.id
        }
    }

    func openFinder(itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }), let url = URL(string: item.url) else { return }
        finderTarget = FinderTarget(id: itemID, url: url)
    }

    func finderCancelled(itemID: UUID) {
        finderTarget = nil
        if let i = items.firstIndex(where: { $0.id == itemID }) {
            items[i].needsFinder = false
            items[i].status = .cancelled
            items[i].detail = ""
        }
        promptNext()
    }

    /// The finder located the file: download it (and its sound, if separate).
    func startDirect(itemID: UUID, job: DirectJob) {
        finderTarget = nil
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[i].direct = job
        items[i].needsFinder = false
        items[i].title = job.title
        items[i].progress = 0
        items[i].status = .waiting
        guard !isRunning else { return }
        isRunning = true
        cancelRequested = false
        Task {
            await download(index: i)
            isRunning = false
            current = nil
            promptNext()
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func cancel() {
        cancelRequested = true
        current?.terminate()
    }

    private func arguments(for item: DownloadItem) -> [String] {
        let url = item.url
        var a = [
            "--newline", "--color", "never", "--no-playlist",
            "-P", folder.path,
            "-o", "%(title)s [%(id)s].%(ext)s",
            "--progress-template", "download:PROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "before_dl:TITLE %(title)s", "--no-simulate",
        ]
        if let ff = ffmpeg {
            a += ["--ffmpeg-location", ff.deletingLastPathComponent().path]
            if quality == .audio {
                a += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
            } else {
                // Prefer H.264 + AAC at each resolution so files play in QuickTime.
                // 1440p/4K on YouTube only exist as VP9/AV1.
                let res = quality.height.map { "res:\($0)" } ?? "res"
                a += ["-f", "bv*+ba/b", "-S", "\(res),vcodec:h264,acodec:m4a", "--merge-output-format", "mp4"]
            }
        } else {
            // No ffmpeg: only single-file formats (usually 720p max, or less).
            if quality == .audio {
                a += ["-f", "ba[ext=m4a]/ba"]
            } else if let h = quality.height {
                a += ["-f", "b[height<=\(h)]/b"]
            } else {
                a += ["-f", "b"]
            }
        }
        // Logins
        if let b = browser.ytdlpName { a += ["--cookies-from-browser", b] }
        let c = item.credentials
        if !c.videoPassword.isEmpty { a += ["--video-password", c.videoPassword] }
        if !c.username.isEmpty { a += ["--username", c.username] }
        if !c.password.isEmpty { a += ["--password", c.password] }

        a += ["--", url]
        return a
    }

    private func download(index i: Int) async {
        items[i].status = .downloading
        items[i].detail = "Starting…"
        appendLog("▶︎ \(items[i].url)")
        lastErrors[i] = nil

        var ok: Bool
        var note = ""
        if let job = items[i].direct {
            (ok, note) = await downloadDirect(index: i, job: job)
            try? FileManager.default.removeItem(at: job.cookiesFile)
        } else {
            ok = await runYtdlp(arguments(for: items[i]), index: i) == 0
        }

        // Let any queued output lines land first.
        await Task.yield()
        if cancelRequested {
            items[i].status = .cancelled
            items[i].detail = ""
        } else if ok {
            items[i].status = .done
            items[i].progress = 1
            items[i].detail = note
        } else {
            let err = lastErrors[i] ?? "The download didn't finish. See the log."
            items[i].status = .failed
            if items[i].direct == nil && isFinderError(err) {
                // The downloader can't read this page: look for the file on the page instead.
                items[i].needsFinder = true
                items[i].detail = "Finding the video on the page…"
            } else {
                items[i].needsAuth = items[i].direct == nil && isAuthError(err)
                items[i].detail = friendly(err)
            }
        }
    }

    private func runYtdlp(_ args: [String], index i: Int) async -> Int32 {
        let dir = folder
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = Tools.ytdlp
            p.arguments = args
            p.environment = Tools.env
            p.currentDirectoryURL = dir
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            let splitter = LineSplitter { [weak self] line in
                Task { @MainActor in self?.handle(line: line, index: i) }
            }
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { splitter.feed(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                splitter.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                splitter.flush()
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
                current = p
            } catch {
                appendLog("Could not start yt-dlp: \(error.localizedDescription)")
                cont.resume(returning: -1)
            }
        }
    }

    // MARK: Files found on a page

    private static let progressTemplate = "download:PROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s"

    private func directArgs(_ job: DirectJob, output: String) -> [String] {
        var a = [
            "--newline", "--color", "never", "--no-playlist",
            "-P", folder.path, "-o", output,
            "--progress-template", Self.progressTemplate,
            "--print", "after_move:FILE %(filepath)s", "--no-simulate",
            "--referer", job.referer,
            "--add-header", "User-Agent:\(job.userAgent)",
            "--cookies", job.cookiesFile.path,
        ]
        if let ff = ffmpeg { a += ["--ffmpeg-location", ff.deletingLastPathComponent().path] }
        return a
    }

    /// Returns (success, note for the row).
    private func downloadDirect(index i: Int, job: DirectJob) async -> (Bool, String) {
        let name = Self.safeName(job.title)
        let template = name.replacingOccurrences(of: "%", with: "%%")

        // A stream link (m3u8/mpd) already describes picture + sound; the downloader joins them.
        if job.primaryIsManifest {
            var a = directArgs(job, output: "\(template).%(ext)s")
            if ffmpeg != nil {
                if quality == .audio {
                    a += ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
                } else {
                    let res = quality.height.map { "res:\($0)" } ?? "res"
                    a += ["-f", "bv*+ba/b", "-S", "\(res),vcodec:h264,acodec:m4a", "--merge-output-format", "mp4"]
                }
            }
            return (await runYtdlp(a + ["--", job.primary], index: i) == 0, "")
        }

        // A whole file: download it, then check it has sound.
        lastFiles[i] = nil
        guard await runYtdlp(directArgs(job, output: "\(template).part-video.%(ext)s") + ["--", job.primary], index: i) == 0,
              let videoPath = lastFiles[i] else { return (false, "") }

        guard let ff = ffmpeg, let probe = Tools.find("ffprobe") else {
            finalize(videoPath, name: name)
            return (true, "")
        }
        let videoStreams = await Self.streams(videoPath, probe: probe)
        if videoStreams.contains("audio") || !videoStreams.contains("video") {
            finalize(videoPath, name: name)
            return (true, "")
        }

        // Picture only: find the separate sound file and join the two.
        var n = 0
        for candidate in job.audioCandidates + job.otherVideos {
            if cancelRequested { break }
            n += 1
            items[i].detail = "Getting the sound…"
            lastFiles[i] = nil
            guard await runYtdlp(directArgs(job, output: "\(template).part-sound\(n).%(ext)s") + ["--", candidate], index: i) == 0,
                  let soundPath = lastFiles[i] else { continue }
            let s = await Self.streams(soundPath, probe: probe)
            guard s.contains("audio"), !s.contains("video") else {
                try? FileManager.default.removeItem(atPath: soundPath)
                continue
            }
            items[i].status = .processing
            items[i].detail = "Joining picture and sound…"
            let out = Self.uniqueURL(in: folder, name: name, ext: "mp4")
            var (code, _) = await Tools.capture(ff.path, ["-y", "-loglevel", "error", "-i", videoPath, "-i", soundPath,
                                                          "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
                                                          "-movflags", "+faststart", out.path])
            if code != 0 {
                (code, _) = await Tools.capture(ff.path, ["-y", "-loglevel", "error", "-i", videoPath, "-i", soundPath,
                                                          "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
                                                          "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out.path])
            }
            if code == 0 {
                try? FileManager.default.removeItem(atPath: videoPath)
                try? FileManager.default.removeItem(atPath: soundPath)
                appendLog("Saved \(out.path)")
                return (true, "")
            }
            try? FileManager.default.removeItem(atPath: soundPath)
        }
        finalize(videoPath, name: name)
        return (true, "Saved, but no sound track was found on the page.")
    }

    private func finalize(_ path: String, name: String) {
        let src = URL(fileURLWithPath: path)
        let dest = Self.uniqueURL(in: src.deletingLastPathComponent(), name: name, ext: src.pathExtension)
        if (try? FileManager.default.moveItem(at: src, to: dest)) != nil { appendLog("Saved \(dest.path)") }
    }

    static func safeName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Webinar" : String(cleaned.prefix(120))
    }

    static func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var url = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// Which kinds of stream ("video", "audio") a file contains.
    static func streams(_ path: String, probe: URL) async -> Set<String> {
        let (_, out) = await Tools.capture(probe.path, ["-v", "error", "-show_entries", "stream=codec_type",
                                                        "-of", "csv=p=0", path])
        return Set(out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private func handle(line: String, index i: Int) {
        if line.hasPrefix("ERROR") { lastErrors[i] = line }
        if line.hasPrefix("FILE ") { lastFiles[i] = String(line.dropFirst(5)) }
        guard items.indices.contains(i), !items[i].status.isFinal else {
            appendLog(line); return
        }
        if line.hasPrefix("PROG ") {
            let parts = line.dropFirst(5).split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let pctStr = parts.first, let pct = Double(pctStr.replacingOccurrences(of: "%", with: "")) {
                items[i].progress = pct / 100
            }
            let speed = parts.count > 1 ? parts[1] : ""
            let eta = parts.count > 2 ? parts[2] : ""
            items[i].status = .downloading
            items[i].detail = [speed, eta.isEmpty || eta == "NA" ? "" : "\(eta) left"]
                .filter { !$0.isEmpty && $0 != "NA" }.joined(separator: " · ")
            return // don't flood the log with progress lines
        }
        if line.hasPrefix("TITLE ") {
            items[i].title = String(line.dropFirst(6))
        } else if line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[VideoConvertor]") || line.hasPrefix("[FixupM3u8]") {
            items[i].status = .processing
            items[i].detail = "Merging / converting…"
        }
        appendLog(line)
    }

    private func isFinderError(_ error: String) -> Bool {
        let e = error.lowercased()
        return ["unsupported url", "no video formats", "unable to extract", "no media", "not a valid url"]
            .contains { e.contains($0) }
    }

    private func isAuthError(_ error: String) -> Bool {
        let e = error.lowercased()
        let hints = ["password", "private video", "sign in", "log in", "login", "logged-in",
                     "authentication", "cookies", "members-only", "registration", "register"]
        return hints.contains { e.contains($0) }
    }

    private func friendly(_ error: String) -> String {
        let e = error.lowercased()
        if e.contains("operation not permitted") && browser == .safari {
            needsFullDiskAccess = true
            return "Pare Reels needs Full Disk Access to use your Safari login (see the note above)."
        }
        if isAuthError(error) {
            return "This video needs a login or password. Click “Unlock…” to enter it."
        }
        if e.contains("unsupported url") { return "This site isn't supported." }
        return error.replacingOccurrences(of: "ERROR: ", with: "")
    }

    private func appendLog(_ s: String) {
        log += s + "\n"
        if log.count > 60_000 { log = String(log.suffix(40_000)) }
    }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var model: DownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste one or more links (one per line)")
                .font(.headline)

            TextEditor(text: $model.urlText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .disabled(model.isRunning)

            HStack(spacing: 16) {
                Picker("Quality", selection: $model.quality) {
                    ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 240)
                .disabled(model.isRunning)

                Picker("Use login from", selection: $model.browser) {
                    ForEach(BrowserLogin.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 240)
                .disabled(model.isRunning)
                .help("For webinars you can only watch when signed in: log in once in that browser, then pick it here.")
                Spacer()
            }

            if model.needsFullDiskAccess {
                HStack {
                    Text("To read your Safari login, turn on Pare Reels under Full Disk Access, then quit and reopen Pare Reels.")
                        .font(.callout).foregroundStyle(.orange)
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                }
            }

            HStack {
                Text("Save to:")
                Text(model.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Change…") { model.chooseFolder() }.disabled(model.isRunning)
                Button("Open Folder") { NSWorkspace.shared.open(model.folder) }
            }

            HStack(spacing: 12) {
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .controlSize(.large)
                } else {
                    Button("Download") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(!model.ready)
                }
                if let msg = model.setupMessage {
                    if !model.setupFailed { ProgressView().controlSize(.small) }
                    Text(msg).foregroundStyle(model.setupFailed ? Color.red : Color.secondary)
                    if model.setupFailed { Button("Retry") { Task { await model.setup() } } }
                }
                if let n = model.notice { Text(n).foregroundStyle(.orange) }
            }

            if model.ready && model.ffmpeg == nil {
                Text("ffmpeg isn't installed, so downloads are limited to lower-quality single files and MP3 isn't available. Fix: run `brew install ffmpeg` in Terminal, then reopen Pare Reels.")
                    .font(.callout).foregroundStyle(.orange)
            }

            List(model.items) { item in
                ItemRow(item: item, canUnlock: !model.isRunning,
                        onUnlock: { model.authItemID = item.id },
                        onFind: { model.openFinder(itemID: item.id) })
            }
            .sheet(item: $model.finderTarget) { target in
                FinderSheet(target: target,
                            onDownload: { job in model.startDirect(itemID: target.id, job: job) },
                            onCancel: { model.finderCancelled(itemID: target.id) })
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 140)

            DisclosureGroup("Log") {
                ScrollView {
                    Text(model.log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
            }
        }
        .padding(20)
        .sheet(item: Binding(
            get: { model.authItemID.flatMap { id in model.items.first { $0.id == id } }.map(AuthTarget.init) },
            set: { model.authItemID = $0?.id }
        )) { target in
            AuthSheet(target: target) { creds in
                model.authItemID = nil
                model.retry(itemID: target.id, with: creds)
            }
            .environmentObject(model)
        }
    }
}

struct AuthTarget: Identifiable {
    let id: UUID
    let label: String
    let credentials: Credentials
    init(_ item: DownloadItem) {
        id = item.id
        label = item.title ?? item.url
        credentials = item.credentials
    }
}

/// Shown when a video needs a password or a login.
struct AuthSheet: View {
    @EnvironmentObject var model: DownloadModel
    @Environment(\.dismiss) private var dismiss
    let target: AuthTarget
    let onRetry: (Credentials) -> Void
    @State private var creds = Credentials()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This video needs access").font(.title3).bold()
            Text(target.label).lineLimit(2).truncationMode(.middle).foregroundStyle(.secondary)

            GroupBox("Option 1: Video password (e.g. Vimeo password-protected)") {
                SecureField("Video password", text: $creds.videoPassword)
                    .textFieldStyle(.roundedBorder)
                    .padding(4)
            }

            GroupBox("Option 2: Use your browser login (most reliable for webinars)") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Browser", selection: $model.browser) {
                        ForEach(BrowserLogin.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text("Log in to the site in that browser first. Chrome-type browsers will ask for your Mac password once: choose Always Allow.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Option 3: Site username and password (works on some sites only)") {
                VStack(spacing: 8) {
                    TextField("Username or email", text: $creds.username)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $creds.password)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(4)
            }

            Text("Passwords are used for this download only and are never saved.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Skip") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { onRetry(creds) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { creds = target.credentials }
    }
}

struct ItemRow: View {
    let item: DownloadItem
    var canUnlock = true
    var onUnlock: () -> Void = {}
    var onFind: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                icon
                Text(item.title ?? item.url).lineLimit(1).truncationMode(.middle)
                Spacer()
                if item.needsFinder && item.status != .waiting && canUnlock {
                    Button("Find Video…", action: onFind).controlSize(.small)
                }
                if item.needsAuth {
                    Button("Unlock…", action: onUnlock).controlSize(.small).disabled(!canUnlock)
                }
                Text(item.status.label).font(.caption).foregroundStyle(.secondary)
            }
            if item.status == .downloading || item.status == .processing {
                ProgressView(value: item.status == .processing ? nil : item.progress)
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption)
                    .foregroundStyle(item.status == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        default: Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        }
    }
}
