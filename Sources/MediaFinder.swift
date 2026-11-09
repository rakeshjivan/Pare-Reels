// MediaFinder — opens a page in a built-in browser and watches for the real
// video/audio files the page's player loads (mp4, m3u8, mpd…), the same thing
// you'd otherwise dig out of the browser's Network inspector by hand.

import SwiftUI
import WebKit

// MARK: - What we found

enum MediaKind: Int, Comparable {
    case manifest = 0   // HLS (.m3u8) / DASH (.mpd): one link that already includes video + sound
    case video = 1      // a whole video file (.mp4, .mov, .webm…)
    case audio = 2      // a whole audio file (.m4a, .mp3…)
    case segment = 3    // a small piece of a stream — ignored

    static func < (a: MediaKind, b: MediaKind) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .manifest: return "Stream"
        case .video: return "Video"
        case .audio: return "Sound"
        case .segment: return "Piece"
        }
    }

    private static let segmentPattern = try! NSRegularExpression(
        pattern: "(seg|segment|chunk|frag|fragment|part)[-_]?\\d+", options: [.caseInsensitive])

    static func classify(_ url: String) -> MediaKind? {
        let lower = url.lowercased()
        let path = (URL(string: url)?.path ?? url).lowercased()
        func ends(_ exts: [String]) -> Bool { exts.contains { path.hasSuffix($0) } }

        if ends([".m3u8", ".mpd"]) || lower.contains(".m3u8") || lower.contains("format=m3u8") { return .manifest }
        if ends([".ts", ".m4s", ".cmfv", ".cmfa"]) { return .segment }
        // Byte-range pieces of a stream (Vimeo and others) are not whole files.
        if lower.contains("/range/") || lower.contains("range=") || lower.contains("bytes=") { return .segment }
        let range = NSRange(path.startIndex..., in: path)
        if segmentPattern.firstMatch(in: path, range: range) != nil { return .segment }
        if ends([".m4a", ".mp3", ".aac", ".opus", ".oga", ".weba"]) || lower.contains("mime=audio") { return .audio }
        if ends([".mp4", ".m4v", ".mov", ".webm", ".mkv"]) || lower.contains("mime=video") {
            // Some players keep the sound in its own .mp4 — say so if the address hints at it.
            return path.contains("audio") ? .audio : .video
        }
        return nil
    }
}

struct MediaCandidate: Identifiable, Hashable {
    let url: String
    let kind: MediaKind
    let order: Int
    var id: String { url }
}

/// Everything needed to download what the finder found, outside the browser.
struct DirectJob {
    var primary: String
    var primaryIsManifest: Bool
    var audioCandidates: [String]
    var otherVideos: [String]
    var referer: String
    var userAgent: String
    var cookiesFile: URL
    var title: String
}

// MARK: - Finder state

@MainActor
final class MediaFinder: ObservableObject {
    @Published private(set) var candidates: [MediaCandidate] = []
    @Published var waitedLong = false
    weak var webView: WKWebView?
    private var started = false

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    var usable: [MediaCandidate] {
        candidates.filter { $0.kind != .segment }.sorted { ($0.kind, $0.order) < ($1.kind, $1.order) }
    }
    var best: MediaCandidate? { usable.first }

    func begin() {
        guard !started else { return }
        started = true
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            waitedLong = true
        }
    }

    func add(_ url: String) {
        guard url.lowercased().hasPrefix("http"),
              !candidates.contains(where: { $0.url == url }),
              let kind = MediaKind.classify(url) else { return }
        candidates.append(MediaCandidate(url: url, kind: kind, order: candidates.count))
    }

    /// Stops playback, saves the browser's login cookies for the downloader, and packages the job.
    func makeJob(selected: String?, pageURL: URL) async -> DirectJob? {
        guard let primary = usable.first(where: { $0.url == selected }) ?? best else { return nil }
        _ = try? await webView?.evaluateJavaScript("window.__pareReelsDone = true; document.querySelectorAll('video,audio').forEach(function(m){m.pause()}); 0")

        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pare-reels-cookies-\(UUID().uuidString).txt")
        var text = "# Netscape HTTP Cookie File\n"
        for c in cookies {
            let domain = (c.isHTTPOnly ? "#HttpOnly_" : "") + c.domain
            let sub = c.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expiry = Int(c.expiresDate?.timeIntervalSince1970 ?? 0)
            text += [domain, sub, c.path, c.isSecure ? "TRUE" : "FALSE", String(expiry), c.name, c.value]
                .joined(separator: "\t") + "\n"
        }
        try? text.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let title = (webView?.title?.isEmpty == false ? webView?.title : nil) ?? "Webinar"
        return DirectJob(
            primary: primary.url,
            primaryIsManifest: primary.kind == .manifest,
            audioCandidates: usable.filter { $0.kind == .audio && $0.url != primary.url }.map(\.url),
            otherVideos: usable.filter { $0.kind == .video && $0.url != primary.url }.map(\.url),
            referer: webView?.url?.absoluteString ?? pageURL.absoluteString,
            userAgent: Self.userAgent,
            cookiesFile: file,
            title: title
        )
    }

    // Injected into every page and frame: reports any media address the page touches.
    static let script = """
    (function(){
      if (window.__pareReels) return; window.__pareReels = true;
      var seen = {};
      var re = /(\\.(m3u8|mpd|mp4|m4v|m4a|mov|webm|mkv|mp3|aac|opus|m4s|ts)([?#]|$))|m3u8|mime=(video|audio)/i;
      function report(u){
        try { u = new URL(u, location.href).href; } catch(e) { return; }
        if (!/^https?:/i.test(u) || seen[u] || !re.test(u)) return;
        seen[u] = 1;
        try { window.webkit.messageHandlers.pareReels.postMessage(u); } catch(e) {}
      }
      try {
        new PerformanceObserver(function(list){ list.getEntries().forEach(function(e){ report(e.name); }); })
          .observe({type: 'resource', buffered: true});
      } catch(e) {}
      // Vimeo's player config lists the streams, including one HLS link with picture + sound.
      function fromVimeoConfig(cfg){
        try {
          var files = cfg && cfg.request && cfg.request.files;
          var hls = files && files.hls;
          if (hls && hls.cdns) {
            var order = [hls.default_cdn].concat(Object.keys(hls.cdns));
            for (var i = 0; i < order.length; i++) {
              var c = hls.cdns[order[i]];
              if (c && c.url) { report(c.url); break; }
            }
          }
          (files && files.progressive || []).forEach(function(p){ if (p && p.url) report(p.url); });
        } catch(e) {}
      }
      function maybeConfig(url, text){
        if (!url || String(url).indexOf('vimeo') < 0 || String(url).indexOf('config') < 0) return;
        try { fromVimeoConfig(JSON.parse(text)); } catch(e) {}
      }
      var f = window.fetch;
      if (f) window.fetch = function(input){
        var u = typeof input === 'string' ? input : (input && input.url);
        try { report(u); } catch(e) {}
        var p = f.apply(this, arguments);
        try { p.then(function(r){ if (String(u).indexOf('config') >= 0) r.clone().text().then(function(t){ maybeConfig(u, t); }); }).catch(function(){}); } catch(e) {}
        return p;
      };
      var open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url){
        try { report(String(url)); } catch(e) {}
        var xhr = this;
        try { xhr.addEventListener('load', function(){ try { maybeConfig(String(url), xhr.responseText); } catch(e) {} }); } catch(e) {}
        return open.apply(this, arguments);
      };
      setInterval(function(){
        if (window.playerConfig) fromVimeoConfig(window.playerConfig);
        document.querySelectorAll('video,audio,source').forEach(function(el){
          report(el.currentSrc || el.src);
        });
        // Start recorded videos muted so their files load without you pressing Play.
        if (!window.__pareReelsDone) document.querySelectorAll('video').forEach(function(v){
          try { v.muted = true; if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function(){}); } } catch(e) {}
        });
      }, 1500);
    })();
    """
}

// MARK: - Built-in browser

struct FinderWebView: NSViewRepresentable {
    let url: URL
    let finder: MediaFinder

    func makeCoordinator() -> Coordinator { Coordinator(finder: finder) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // keeps you logged in between uses
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: MediaFinder.script,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.add(context.coordinator, name: "pareReels")
        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = MediaFinder.userAgent
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        finder.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "pareReels")
        nsView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        weak var finder: MediaFinder?
        init(finder: MediaFinder) { self.finder = finder }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let u = message.body as? String else { return }
            Task { @MainActor [weak finder] in finder?.add(u) }
        }

        // Links that open a new window (common for "Watch recording" buttons) open here instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        // A link straight to a video file: record it rather than letting the browser try to save it.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let mime = navigationResponse.response.mimeType?.lowercased() ?? ""
            if let u = navigationResponse.response.url?.absoluteString,
               mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime.contains("mpegurl") || mime.contains("dash+xml") {
                Task { @MainActor [weak finder] in finder?.add(u) }
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Finder window

struct FinderTarget: Identifiable {
    let id: UUID      // the download item this is for
    let url: URL
}

struct FinderSheet: View {
    let target: FinderTarget
    let onDownload: (DirectJob) -> Void
    let onCancel: () -> Void
    @StateObject private var finder = MediaFinder()
    @State private var handedOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).font(.headline)
            }
            Text("This window closes by itself once the video is found. If the page asks you to log in, register or click Play, do that here.")
                .font(.callout).foregroundStyle(.secondary)

            FinderWebView(url: target.url, finder: finder)
                .frame(minHeight: 420)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 600)
        .onAppear { finder.begin() }
        .onChange(of: finder.usable.count) { _ in scheduleHandOff() }
    }

    private var status: String {
        if handedOff { return "Found it. Starting download…" }
        if finder.best != nil { return "Found the video. Checking for a separate sound file…" }
        return finder.waitedLong ? "Still looking. Press Play on the video if it hasn't started." : "Finding the video…"
    }

    /// Wait a few seconds after the first find so a separate sound file can show up too, then go.
    private func scheduleHandOff() {
        guard !handedOff, finder.best != nil else { return }
        let delay: UInt64 = finder.best?.kind == .manifest ? 2 : 5
        Task {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !handedOff, let job = await finder.makeJob(selected: nil, pageURL: target.url) else { return }
            handedOff = true
            onDownload(job)
        }
    }
}
