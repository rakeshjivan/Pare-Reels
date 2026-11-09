// Updater — checks GitHub for a newer Pare Reels when the app opens, downloads it
// in the background, and swaps it in when you quit (or straight away via "Restart Now").

import SwiftUI
import AppKit

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var readyBuild: Int?
    @Published private(set) var downloading = false

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

    func check() async {
        guard currentBuild > 0, readyBuild == nil, !downloading else { return }
        var req = URLRequest(url: Self.latestAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PareReels/\(currentBuild)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let latest = Int(release.tag_name.replacingOccurrences(of: "build-", with: "")),
              latest > currentBuild,
              let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix("mac.zip") })
        else { return }

        downloading = true
        defer { downloading = false }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PareReelsUpdate-\(latest)")
        do {
            try? fm.removeItem(at: work)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            try await Tools.download(asset.browser_download_url, to: zip)
            let status = await Task.detached { (try? Tools.runQuick("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])) ?? -1 }.value
            guard status == 0,
                  let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }),
                  Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
            else { return }
            _ = try? Tools.runQuick("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            stagedApp = app
            readyBuild = latest
        } catch {
            try? fm.removeItem(at: work)
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
