// Updater — checks GitHub for a newer Pare Reels when the app opens, downloads it
// in the background, and swaps it in when you quit (or straight away via "Restart Now").

import SwiftUI
import AppKit

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var readyBuild: Int?
    @Published private(set) var downloading = false
    @Published private(set) var checking = false
    @Published private(set) var statusText: String?

    /// Build number baked in by GitHub (0 for builds made on your own Mac, which never auto-update).
    let currentBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
    private var stagedApp: URL?

    private static let latestAPI = URL(string: "https://api.github.com/repos/rakeshjivan/Pare-Reels/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/rakeshjivan/Pare-Reels/releases/latest")!

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let assets: [Asset]
    }

    /// Manual "Check for Updates": same as the launch check, but says what happened.
    func checkNow() async {
        guard !checking, !downloading else { return }
        if readyBuild != nil { install(relaunch: true); return }
        guard currentBuild > 0 else {
            statusText = "This copy was built on your Mac, so it doesn't auto-update."
            return
        }
        checking = true
        statusText = "Checking…"
        let found = await check()
        checking = false
        switch found {
        case .updated(let b): statusText = "Build \(b) downloaded. Click Restart to Update."
        case .upToDate: statusText = "You're up to date (build \(currentBuild))."
        case .failed: statusText = "Couldn't check right now. Try again later."
        }
    }

    enum Result { case updated(Int), upToDate, failed }

    private static func latestBuild() async -> Int? {
        var req = URLRequest(url: releasesPage)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 20
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let tag = http.url?.lastPathComponent, tag.hasPrefix("build-"),
           let n = Int(tag.dropFirst(6)) {
            return n
        }
        // Fallback: GitHub's API.
        var api = URLRequest(url: latestAPI)
        api.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        api.setValue("PareReels", forHTTPHeaderField: "User-Agent")
        api.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: api),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        return Int(release.tag_name.replacingOccurrences(of: "build-", with: ""))
    }

    @discardableResult
    func check() async -> Result {
        guard currentBuild > 0, readyBuild == nil, !downloading else { return readyBuild.map { Result.updated($0) } ?? Result.upToDate }
        // Ask github.com which release is newest: it redirects .../releases/latest to .../tag/build-N.
        // (Unlike GitHub's API, this isn't limited to 60 checks an hour.)
        guard let latest = await Self.latestBuild() else { return .failed }
        guard latest > currentBuild else { return .upToDate }
        let assetURL = "https://github.com/rakeshjivan/Pare-Reels/releases/download/build-\(latest)/Pare-Reels-mac.zip"

        downloading = true
        statusText = "Downloading build \(latest)…"
        defer { downloading = false }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PareReelsUpdate-\(latest)")
        do {
            try? fm.removeItem(at: work)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            try await Tools.download(assetURL, to: zip)
            let status = await Task.detached { (try? Tools.runQuick("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])) ?? -1 }.value
            guard status == 0,
                  let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
            else { return .failed }
            _ = try? Tools.runQuick("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            stagedApp = app
            readyBuild = latest
            statusText = nil
            return .updated(latest)
        } catch {
            try? fm.removeItem(at: work)
            return .failed
        }
    }

    /// Replaces this app with the downloaded one once it has quit; optionally reopens it.
    func install(relaunch: Bool) {
        guard let newApp = stagedApp else { return }
        stagedApp = nil
        let oldApp = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: oldApp.deletingLastPathComponent().path) else {
            NSWorkspace.shared.open(Self.releasesPage)   // can't replace it here: send you to the download page
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "$OLD.previous"
        if mv "$OLD" "$OLD.previous" && mv "$NEW" "$OLD"; then
          rm -rf "$OLD.previous"
        elif [ -d "$OLD.previous" ] && [ ! -d "$OLD" ]; then
          mv "$OLD.previous" "$OLD"
        fi
        if [ "$RELAUNCH" = "1" ]; then open "$OLD"; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["OLD": oldApp.path, "NEW": newApp.path, "RELAUNCH": relaunch ? "1" : "0",
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        if relaunch { NSApp.terminate(nil) }
    }
}

/// The small strip shown when an update is waiting.
struct UpdateBanner: View {
    @ObservedObject var updater = Updater.shared
    let busy: Bool

    var body: some View {
        if let build = updater.readyBuild {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.app.fill").foregroundStyle(.blue)
                Text("A new version (build \(build)) is ready. It installs when you quit.")
                Spacer()
                Button("Restart Now") { updater.install(relaunch: true) }
                    .disabled(busy)
            }
            .font(.callout)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08)))
        }
    }
}

/// "Check for Updates" / "Restart to Update", with a one-line result next to it.
struct UpdateButton: View {
    @ObservedObject var updater = Updater.shared
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let t = updater.statusText {
                Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if updater.checking || updater.downloading { ProgressView().controlSize(.small) }
            Button(updater.readyBuild != nil ? "Restart to Update" : "Check for Updates") {
                Task { await updater.checkNow() }
            }
            .disabled(busy || updater.checking || updater.downloading)
        }
    }
}
