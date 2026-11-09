// Crop tab — open a video, drag the handles, save.
// Instant: lossless, rewrites the crop setting inside the H.264/HEVC stream (seconds, no quality loss).
// Fast: re-encodes with the Mac's hardware video encoder (minutes, smaller file, works everywhere).

import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Aspect presets

enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free"
    case wide = "16:9"
    case square = "1:1"
    case vertical = "9:16"
    case portrait = "4:5"
    case classic = "4:3"

    var id: String { rawValue }
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .wide: return 16.0 / 9.0
        case .square: return 1
        case .vertical: return 9.0 / 16.0
        case .portrait: return 4.0 / 5.0
        case .classic: return 4.0 / 3.0
        }
    }
}

enum CropHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    var left: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var right: Bool { self == .topRight || self == .right || self == .bottomRight }
    var top: Bool { self == .topLeft || self == .top || self == .topRight }
    var bottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    var isCorner: Bool { (left || right) && (top || bottom) }
    /// Position on the crop box, 0...1 in each direction.
    var anchor: CGPoint {
        CGPoint(x: left ? 0 : (right ? 1 : 0.5), y: top ? 0 : (bottom ? 1 : 0.5))
    }
}

// MARK: - Model

@MainActor
final class CropModel: ObservableObject {
    @Published var url: URL?
    @Published var videoSize: CGSize = .zero        // as displayed (rotation applied)
    @Published var frame: CGImage?
    @Published var duration: Double = 0
    @Published var time: Double = 0
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1)   // 0...1 of the frame
    @Published var aspect: CropAspect = .free { didSet { applyAspect() } }
    @Published var codec = ""
    @Published var fps: Double = 30
    /// Compress & Save found nothing to gain: ask whether to save the crop/trim without compressing.
    @Published var offerPlainSave = false
    @Published var rotated = false
    @Published var busy = false
    @Published var progress: Double?
    @Published var liveInfo: String?          // e.g. "14× · about 8 min left"
    private var exportSession: AVAssetExportSession?
    private var exportError: String?
    private var fastEncoder = ""
    @Published var status: String?
    @Published var savedFile: URL?

    private var generator: AVAssetImageGenerator?
    private var frameRequest = 0
    private var process: Process?
    private var cancelled = false

    var isCropped: Bool { crop.minX > 0.001 || crop.minY > 0.001 || crop.width < 0.999 || crop.height < 0.999 }
    /// Areas to blur (0...1 of the frame), for names, faces or IDs. Blurred for the whole video.
    @Published var blurs: [CGRect] = []
    /// 1 = normal; 1.5 = one and a half times as fast (voices keep their normal pitch).
    @Published var speed: Double = 1
    /// Anything that needs the picture rebuilt besides a crop.
    var hasEffects: Bool { !blurs.isEmpty || abs(speed - 1) > 0.001 }
    func addBlur() { blurs.append(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)) }
    var isTrimmed: Bool { trimStart > 0.05 || trimEnd < duration - 0.05 }
    /// Trimming alone works on any video; cropping instantly needs H.264/HEVC that isn't rotated.
    var canInstant: Bool { !isCropped || ((codec == "h264" || codec == "hevc") && !rotated) }

    func setStart() { trimStart = min(time, max(0, trimEnd - 0.5)) }
    func setEnd() { trimEnd = max(time, min(duration, trimStart + 0.5)) }
    func clearTrim() { trimStart = 0; trimEnd = duration }

    func pixels(_ n: CGRect) -> CGRect {
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        let W = videoSize.width, H = videoSize.height
        var x = even(n.minX * W), y = even(n.minY * H)
        var w = even(n.width * W), h = even(n.height * H)
        w = max(16, min(w, even(W - x))); h = max(16, min(h, even(H - y)))
        x = max(0, min(x, W - w)); y = max(0, min(y, H - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Free resize (no shape lock), used for blur boxes.
    func resizedFree(from s: CGRect, handle: CropHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minSize: CGFloat = 0.02
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if handle.left { minX = min(max(0, minX + dx), maxX - minSize) }
        if handle.right { maxX = max(min(1, maxX + dx), minX + minSize) }
        if handle.top { minY = min(max(0, minY + dy), maxY - minSize) }
        if handle.bottom { maxY = max(min(1, maxY + dy), minY + minSize) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var pixelRect: CGRect {
        // Whole, even pixel values (needed by the video formats).
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        let W = videoSize.width, H = videoSize.height
        var x = even(crop.minX * W), y = even(crop.minY * H)
        var w = even(crop.width * W), h = even(crop.height * H)
        w = max(16, min(w, even(W - x))); h = max(16, min(h, even(H - y)))
        x = min(x, W - w); y = min(y, H - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Height per width, in 0...1 units, for the chosen aspect.
    private var aspectK: CGFloat? {
        guard let r = aspect.ratio, videoSize.width > 0, videoSize.height > 0 else { return nil }
        return videoSize.width / (r * videoSize.height)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url { Task { await open(u) } }
    }

    func open(_ url: URL) async {
        status = nil; savedFile = nil
        let asset = AVURLAsset(url: url)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                status = "That file has no video."; return
            }
            let natural = try await track.load(.naturalSize)
            let t = try await track.load(.preferredTransform)
            let shown = natural.applying(t)
            videoSize = CGSize(width: abs(shown.width), height: abs(shown.height))
            rotated = !(t.a == 1 && t.d == 1 && t.b == 0 && t.c == 0)
            duration = try await asset.load(.duration).seconds
            let rate = try await track.load(.nominalFrameRate)
            fps = rate > 0 ? Double(rate) : 30
            let fds = try await track.load(.formatDescriptions)
            let subtype: FourCharCode = fds.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            switch subtype {
            case kCMVideoCodecType_H264: codec = "h264"
            case kCMVideoCodecType_HEVC, 0x68657631 /* hev1 */: codec = "hevc"
            default: codec = "other"
            }
        } catch {
            status = "Couldn't open that video: \(error.localizedDescription)"
            return
        }
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 1600, height: 1600)
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator = g
        self.url = url
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        blurs = []; speed = 1
        applyAspect()
        trimStart = 0
        trimEnd = duration
        time = min(duration * 0.1, 10)
        await refreshFrame()
    }

    func refreshFrame() async {
        guard let g = generator else { return }
        frameRequest += 1
        let mine = frameRequest
        let t = CMTime(seconds: time, preferredTimescale: 600)
        if let result = try? await g.image(at: t), mine == frameRequest {
            frame = result.image
        }
    }

    func applyAspect() {
        guard let k = aspectK else { return }
        var w: CGFloat = 1, h = k
        if h > 1 { h = 1; w = 1 / k }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    func resized(from s: CGRect, handle: CropHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minSize: CGFloat = 0.05
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        if handle.left { minX = min(max(0, minX + dx), maxX - minSize) }
        if handle.right { maxX = max(min(1, maxX + dx), minX + minSize) }
        if handle.top { minY = min(max(0, minY + dy), maxY - minSize) }
        if handle.bottom { maxY = max(min(1, maxY + dy), minY + minSize) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let k = aspectK else { return r }
        if handle.left || handle.right {
            let h = r.width * k
            r.origin.y = handle.top ? s.maxY - h : (handle.bottom ? s.minY : s.midY - h / 2)
            r.size.height = h
        } else {
            let w = r.height / k
            r.origin.x = s.midX - w / 2
            r.size.width = w
        }
        let inside = r.minX >= -0.0001 && r.minY >= -0.0001 && r.maxX <= 1.0001 && r.maxY <= 1.0001
        return inside && r.width >= minSize && r.height >= minSize ? r : s
    }

    func moved(from s: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var r = s
        r.origin.x = min(max(0, s.minX + dx), 1 - s.width)
        r.origin.y = min(max(0, s.minY + dy), 1 - s.height)
        return r
    }

    func reset() {
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        blurs = []; speed = 1
        applyAspect()
    }

    // MARK: Saving

    enum SaveMethod: String { case instant = "instant", fast = "fast", secure = "secure" }
    private var method: SaveMethod = .instant
    lazy var secure = SecureSaver()   // browser engine, kept for testing the Pare web tool (not shown)

    func cancel() {
        cancelled = true
        process?.terminate()
        extraProcesses.forEach { $0.terminate() }
        exportSession?.cancelExport()
        if method == .secure { secure.cancel() }
    }

    private var compressing = false
    private var suffix: String {
        let base: String
        switch (isCropped || hasEffects, isTrimmed) {
        case _ where hasEffects: base = "edited"
        case (true, true): base = "edited"
        case (false, true): base = "trimmed"
        case (true, false): base = "cropped"
        default: base = ""
        }
        if compressing { return base.isEmpty ? "compressed" : base + ", compressed" }
        return base.isEmpty ? "copy" : base
    }

    private func outputURL(for src: URL, ext: String) -> URL {
        var dir = src.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: dir.path) {
            dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        let base = src.deletingPathExtension().lastPathComponent + " (\(suffix))"
        return DownloadModel.uniqueURL(in: dir, name: base, ext: ext)
    }

    func save(_ how: SaveMethod, compress: Bool = false) {
        let instant = how == .instant
        guard let src = url, !busy else { return }
        guard compress || isCropped || isTrimmed || hasEffects else {
            status = "Nothing to change yet. Drag the crop handles or set a start or end point."
            return
        }
        guard let ff = Tools.find("ffmpeg") else {
            status = "ffmpeg isn't installed yet. Open the Download tab once so Pare Reels can fetch it."
            return
        }
        method = how
        compressing = compress
        liveInfo = nil
        busy = true; cancelled = false; savedFile = nil
        progress = instant ? nil : 0
        status = compress ? "Compressing…" : ["instant": "Saving (instant)…", "fast": "Saving…", "secure": "Saving (secure, browser engine)…"][how.rawValue]
        let rect = pixelRect
        let started = Date()
        Task {
            var note = ""
            var result: URL?
            switch how {
            case .instant: result = await saveInstant(src: src, ff: ff, rect: rect)
            case .fast where compress:
                // Smallest file that still looks the same: test a few quality levels on samples,
                // then encode in HEVC with change-only encoding, pieces shared out to the workers.
                compressRefusal = nil
                guard let pick = await pickQuality(src: src, ff: ff, rect: rect), !cancelled else { break }
                let enc = ["-c:v", "hevc_videotoolbox", "-q:v", "\(pick.q)", "-tag:v", "hvc1"]
                if let r = await saveParallel(src: src, ff: ff, rect: rect, encoder: enc, audio: "128k") {
                    result = r
                    note = " Quality: \(pick.label). Engine: \(fastEncoder), HEVC."
                }
            case .fast where !isCropped && !hasEffects:
                // Trim only: no rebuild needed — instant, works in every player.
                result = await saveInstant(src: src, ff: ff, rect: rect)
                note = " Trimmed instantly (starts at the nearest keyframe, up to a few seconds early)."
            case .fast:
                // Main engine: parts side by side, change-only encoding, Mac hardware.
                if let r = await saveParallel(src: src, ff: ff, rect: rect,
                                              encoder: ["-c:v", "h264_videotoolbox", "-prio_speed", "1", "-q:v", "65"], audio: "192k") {
                    result = r
                    note = " Engine: \(fastEncoder)."
                } else if !cancelled, let r = await saveFast(src: src, ff: ff, rect: rect) {
                    result = r
                    note = " Engine: \(fastEncoder)."
                } else if !cancelled, !hasEffects, let r = await saveApple(src: src, rect: rect) {
                    result = r
                    note = " (Used the backup engine: Apple export.)"
                }
            case .secure:
                let out = outputURL(for: src, ext: "mp4")
                secure.onProgress = { [weak self] p in self?.progress = p }
                switch await secure.run(src: src, crop: isCropped ? rect : nil,
                                        start: isTrimmed ? trimStart : 0, end: isTrimmed ? trimEnd : duration, output: out) {
                case .saved(let jsMs, let enc):
                    result = out
                    note = " Browser engine: \(String(format: "%.1f", Double(jsMs) / 1000)) s, encoder \(enc)."
                case .failed(let message):
                    try? FileManager.default.removeItem(at: out)
                    note = message
                case .cancelled:
                    try? FileManager.default.removeItem(at: out)
                }
            }
            let secs = Date().timeIntervalSince(started)
            busy = false
            progress = nil
            liveInfo = nil
            if cancelled {
                status = "Cancelled."
            } else if compress, let out = result,
                      let inB = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value,
                      let outB = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value,
                      outB >= inB, !isCropped, !isTrimmed, !hasEffects {
                try? FileManager.default.removeItem(at: out)
                status = "The compressed file came out no smaller than the original, so it was discarded. This video is already compressed about as far as it can go."
            } else if let out = result {
                savedFile = out
                let mb = Double((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576
                let media = (isTrimmed ? trimEnd - trimStart : duration) / speed
                let speed = secs > 0 ? String(format: " · %.1f× real time", media / secs) : ""
                var smaller = ""
                if compress, let inBytes = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.doubleValue, inBytes > 0 {
                    smaller = String(format: " (was %.0f MB, %.0f%% smaller)", inBytes / 1_048_576, max(0, 100 - mb * 1_048_576 / inBytes * 100))
                }
                status = "Saved “\(out.lastPathComponent)” in \(Self.duration(secs))\(speed) · \(String(format: "%.0f", mb)) MB\(smaller).\(note)"
            } else {
                if compress, compressRefusal != nil, isCropped || isTrimmed || hasEffects { offerPlainSave = true }
                status = compress && compressRefusal != nil ? compressRefusal
                    : how == .secure ? "Secure save failed: \(note)"
                    : instant ? "Instant save didn't work for this file. Try Fast instead." : "Saving failed. See details in the Download tab's Log."
            }
        }
    }

    static func duration(_ s: Double) -> String {
        s < 60 ? String(format: "%.1f s", s) : String(format: "%d min %02d s", Int(s) / 60, Int(s) % 60)
    }

    private func saveInstant(src: URL, ff: URL, rect: CGRect) async -> URL? {
        let W = videoSize.width, H = videoSize.height
        // The stored picture is padded up to whole blocks (e.g. 1080 is stored as 1088 in H.264).
        let block: CGFloat = codec == "h264" ? 16 : 8
        let padW = (W / block).rounded(.up) * block - W
        let padH = (H / block).rounded(.up) * block - H
        let l = Int(rect.minX), t = Int(rect.minY)
        let r = Int(W - rect.maxX + padW), b = Int(H - rect.maxY + padH)
        let bsf = (codec == "h264" ? "h264_metadata" : "hevc_metadata")
            + "=crop_left=\(l):crop_right=\(r):crop_top=\(t):crop_bottom=\(b)"
        let ext = ["mov", "mp4", "m4v"].contains(src.pathExtension.lowercased()) ? src.pathExtension.lowercased() : "mp4"
        let out = outputURL(for: src, ext: ext)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pare-crop-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Pass 1: cut to the chosen range and change the crop inside the video stream (no re-encoding).
        var a1 = ["-y", "-loglevel", "error"]
        if isTrimmed && trimStart > 0 { a1 += ["-ss", String(format: "%.3f", trimStart)] }
        a1 += ["-i", src.path]
        if isTrimmed { a1 += ["-t", String(format: "%.3f", trimEnd - trimStart)] }
        a1 += ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
        if isCropped { a1 += ["-bsf:v", bsf] }
        a1 += ["-avoid_negative_ts", "make_zero", tmp.path]
        guard await run(ff, a1) == 0, !cancelled else { return nil }
        // Pass 2: rewrite the file so its stated size matches the new picture.
        var args = ["-y", "-loglevel", "error", "-i", tmp.path, "-map", "0", "-c", "copy"]
        if codec == "hevc" && isCropped { args += ["-tag:v", "hvc1"] }
        args += ["-movflags", "+faststart", out.path]
        guard await run(ff, args) == 0, !cancelled else { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    /// Apple's export pipeline (what Photos uses): decode, crop and encode all stay on the video hardware.
    private func saveApple(src: URL, rect: CGRect) async -> URL? {
        exportError = nil
        let asset = AVURLAsset(url: src)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let transform = try? await track.load(.preferredTransform) else { exportError = "no video track"; return nil }
        let fps = (try? await track.load(.nominalFrameRate)) ?? 30
        let total = (try? await asset.load(.duration)) ?? CMTime(seconds: duration, preferredTimescale: 600)
        let range = isTrimmed
            ? CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), end: CMTime(seconds: trimEnd, preferredTimescale: 600))
            : CMTimeRange(start: .zero, duration: total)
        let box = isCropped ? rect : CGRect(origin: .zero, size: videoSize)

        let comp = AVMutableVideoComposition()
        comp.renderSize = box.size
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(60, max(1, fps > 0 ? fps.rounded() : 30))))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: total)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY)), at: .zero)
        instruction.layerInstructions = [layer]
        comp.instructions = [instruction]

        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            exportError = "export not available"; return nil
        }
        let out = outputURL(for: src, ext: "mp4")
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.videoComposition = comp
        ex.timeRange = range
        ex.shouldOptimizeForNetworkUse = true
        exportSession = ex

        let started = Date(), mediaLen = range.duration.seconds
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let p = Double(ex.progress)
                self?.progress = p
                let elapsed = Date().timeIntervalSince(started)
                if elapsed < 30 || p < 0.02 {
                    self?.liveInfo = "estimating time…"
                } else {
                    let speed = p * mediaLen / elapsed
                    let left = elapsed * (1 - p) / p
                    self?.liveInfo = String(format: "%.1f×", speed) + " · " + (left < 60 ? "under a minute left" : "about \(Int((left / 60).rounded())) min left")
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        poll.cancel()
        exportSession = nil
        if ex.status == .completed { return out }
        exportError = ex.error?.localizedDescription ?? "status \(ex.status.rawValue)"
        try? FileManager.default.removeItem(at: out)
        return nil
    }

    private var extraProcesses: [Process] = []

    /// Runs one ffmpeg job and reports how far through its media it is (seconds).
    private func runTracked(_ exe: URL, _ args: [String], onTime: @escaping @Sendable (Double) -> Void) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            let splitter = LineSplitter { line in
                if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) { onTime(us / 1_000_000) }
            }
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { splitter.feed(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run(); extraProcesses.append(p) } catch { cont.resume(returning: -1) }
        }
    }

    private func cropFilter(_ rect: CGRect) -> String {
        "crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))"
    }

    /// Blur boxes, then the crop: everything that changes how the picture looks (no timing changes).
    /// Blurs are heavy (three passes) so names and faces can't be read back.
    private func lookFilter(_ rect: CGRect) -> String? {
        var parts: [String] = []
        for (i, b) in blurs.enumerated() {
            let p = pixels(b)
            let w = Int(p.width), h = Int(p.height), x = Int(p.minX), y = Int(p.minY)
            let r = max(1, min(min(w, h) / 2 - 1, 40)), rc = max(1, min(r, min(w, h) / 4 - 1))
            parts.append("split[m\(i)][s\(i)];[s\(i)]crop=\(w):\(h):\(x):\(y),boxblur=luma_radius=\(r):luma_power=3:chroma_radius=\(rc):chroma_power=3[b\(i)];[m\(i)][b\(i)]overlay=\(x):\(y)")
        }
        if isCropped { parts.append(cropFilter(rect)) }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// Runs ffmpeg and returns its messages (where it reports quality scores).
    private func runForLog(_ exe: URL, _ args: [String]) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe()
            p.standardError = pipe
            p.standardOutput = FileHandle.nullDevice
            final class Buf: @unchecked Sendable { var data = Data(); let lock = NSLock() }
            let buf = Buf()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { buf.lock.lock(); buf.data.append(d); buf.lock.unlock() }
            }
            p.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                buf.lock.lock(); buf.data.append(rest); let all = String(decoding: buf.data, as: UTF8.self); buf.lock.unlock()
                cont.resume(returning: all)
            }
            do { try p.run(); extraProcesses.append(p) } catch { cont.resume(returning: "") }
        }
    }

    /// Finds the lowest HEVC quality setting whose result still looks the same as the original.
    /// Short samples from the start, middle and end are encoded at a few settings and scored with
    /// VMAF (Netflix's measure; 95+ looks the same to most viewers), or SSIM if VMAF isn't available.
    /// Returns nil (with the reason in `compressRefusal`) when the video can't get smaller without visible loss.
    private var compressRefusal: String?
    private func pickQuality(src: URL, ff: URL, rect: CGRect) async -> (q: Int, label: String)? {
        let mediaLen = isTrimmed ? trimEnd - trimStart : duration
        let start = isTrimmed ? trimStart : 0
        let sampleLen = min(8.0, mediaLen)
        let spots: [Double] = mediaLen >= 60 ? [0.2, 0.5, 0.8] : [0]
        let at = spots.map { start + $0 * max(0, mediaLen - sampleLen) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pare-q-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let crop = lookFilter(rect).map { [$0] } ?? []
        let vmaf = (await runForLogOut(ff, ["-hide_banner", "-filters"])).contains("libvmaf")

        // Score one quality setting: the worst of the samples.
        func score(_ q: Int) async -> (Double, Double) {
            await withTaskGroup(of: (Double, Double).self) { group in
                for (i, a) in at.enumerated() {
                    group.addTask {
                        let out = work.appendingPathComponent("q\(q)-\(i).mp4")
                        let ss = String(format: "%.3f", a), len = String(format: "%.3f", sampleLen)
                        var enc = ["-y", "-loglevel", "error", "-hwaccel", "videotoolbox", "-ss", ss, "-i", src.path, "-t", len,
                                   "-map", "0:v:0", "-an"]
                        if !crop.isEmpty { enc += ["-vf", crop[0]] }
                        enc += ["-c:v", "hevc_videotoolbox", "-q:v", "\(q)", "-tag:v", "hvc1", out.path]
                        _ = await self.runForLog(ff, enc)
                        let ref = (crop.isEmpty ? "" : crop[0] + ",") + "setpts=PTS-STARTPTS"
                        let metric = vmaf ? "libvmaf=n_threads=4:n_subsample=2" : "ssim"
                        let log = await self.runForLog(ff, ["-hide_banner", "-nostats", "-i", out.path, "-ss", ss, "-t", len, "-i", src.path,
                            "-lavfi", "[0:v]setpts=PTS-STARTPTS[d];[1:v]\(ref)[r];[d][r]\(metric)", "-f", "null", "-"])
                        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.doubleValue ?? 0
                        return (Self.parseScore(log, vmaf: vmaf), bytes)
                    }
                }
                var worst = Double.infinity, bytes = 0.0
                for await (v, b) in group { worst = min(worst, v); bytes += b }
                return (worst == .infinity ? 0 : worst, bytes)
            }
        }
        // The original's bit rate, for judging whether the result would actually be smaller.
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let sourceRate = duration > 0 ? fileBytes * 8 / duration : 0
        let target = vmaf ? 95.0 : 0.985
        let levels = [45, 52, 59, 66, 73]
        var lo = 0, hi = levels.count - 1, best: (Int, Double, Double)? = nil, tests = 0
        while lo <= hi, !cancelled {          // binary search for the lowest setting that passes
            let mid = (lo + hi) / 2
            tests += 1
            liveInfo = "finding the smallest size that still looks the same (test \(tests))…"
            let (v, bytes) = await score(levels[mid])
            if v >= target { best = (levels[mid], v, bytes); hi = mid - 1 } else { lo = mid + 1 }
        }
        liveInfo = nil
        guard let b = best else {
            compressRefusal = "This video is already compressed about as far as it can go: even the highest quality setting tested didn't look the same as the original, so no file was made."
            return nil
        }
        // Would it actually be smaller? (Samples are a fair guide; change-only encoding usually saves a bit more.)
        let sampleRate = b.2 * 8 / (sampleLen * Double(at.count))
        if sourceRate > 0, sampleRate > sourceRate * 0.9 {
            compressRefusal = String(format: "This video is already compressed about as far as it can go: keeping it looking the same would need about %.1f Mbps, and the original is only %.1f Mbps. No file was made, so nothing changed.", sampleRate / 1e6, sourceRate / 1e6)
            return nil
        }
        return (b.0, vmaf ? String(format: "VMAF %.1f, looks the same", b.1) : String(format: "SSIM %.3f", b.1))
    }

    private func runForLogOut(_ exe: URL, _ args: [String]) async -> String {
        let (_, out) = await Tools.capture(exe.path, args)
        return out
    }

    nonisolated static func parseScore(_ log: String, vmaf: Bool) -> Double {
        if vmaf {
            guard let r = log.range(of: "VMAF score: ", options: .backwards) else { return 0 }
            return Double(log[r.upperBound...].prefix { "0123456789.".contains($0) }) ?? 0
        }
        guard let r = log.range(of: "All:", options: .backwards) else { return 0 }
        return Double(log[r.upperBound...].prefix { "0123456789.".contains($0) }) ?? 0
    }

    /// Crop save for long videos: split into parts, process them side by side with change-only
    /// encoding on the Mac's video hardware, then join losslessly and add the original sound.
    private func saveParallel(src: URL, ff: URL, rect: CGRect, encoder: [String], audio: String) async -> URL? {
        let mediaLen = isTrimmed ? trimEnd - trimStart : duration
        let start = isTrimmed ? trimStart : 0
        let cores = ProcessInfo.processInfo.activeProcessorCount
        // The Mac's video hardware decodes up to 4 parts; extra parts are decoded by the
        // processor cores, which would otherwise sit idle.
        let n = mediaLen < 180 ? 1 : min(8, max(2, cores - 2))
        let hwParts = min(n, 4)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pare-parts-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let sp = speed
        let filter = (lookFilter(rect).map { $0 + "," } ?? "") + "mpdecimate=hi=256:lo=128:frac=0.1:max=30"
            + (abs(sp - 1) > 0.001 ? String(format: ",setpts=PTS/%.4f", sp) : "")
        fastEncoder = "Mac hardware, change-only encoding, \(n) at once"
            + (n > hwParts ? " (\(n - hwParts) decoded by the processor)" : "")

        // Many small pieces handed out to the workers as they free up: the faster hardware
        // workers simply take more pieces, so everyone finishes together.
        let pieces = max(n, min(n * 4, Int(mediaLen / 60)))
        final class Done: @unchecked Sendable { var seconds = 0.0 }
        let done = (0..<pieces).map { _ in Done() }
        var parts: [(URL, Double)] = []
        var jobs: [[String]] = []
        for i in 0..<pieces {
            let a = start + Double(i) * mediaLen / Double(pieces)
            let b = i == pieces - 1 ? start + mediaLen : start + Double(i + 1) * mediaLen / Double(pieces)
            let out = work.appendingPathComponent("part\(i).mp4")
            parts.append((out, (b - a) / sp))
            // -t before -i: limits how much of the original is read (so pieces never overlap, even when sped up).
            jobs.append(["-ss", String(format: "%.3f", a), "-t", String(format: "%.3f", b - a), "-i", src.path,
                         "-map", "0:v:0", "-an", "-vf", filter, "-fps_mode", "vfr",
                         ] + encoder + [out.path])
        }
        final class Line: @unchecked Sendable {
            private var next = 0; private let lock = NSLock(); let count: Int
            init(_ count: Int) { self.count = count }
            func take() -> Int? { lock.lock(); defer { lock.unlock() }; guard next < count else { return nil }; next += 1; return next - 1 }
        }
        let line = Line(pieces)
        let allJobs = jobs

        let started = Date()
        let poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let sum = done.map(\.seconds).reduce(0, +) * sp   // pieces report output time
                let elapsed = Date().timeIntervalSince(started)
                self?.progress = min(0.98, sum / mediaLen)
                if elapsed > 20, sum > 0 {
                    let speed = sum / elapsed, left = (mediaLen - sum) / speed
                    self?.liveInfo = String(format: "%.1f× · %d at once · ", speed, n)
                        + (left < 60 ? "under a minute left" : "about \(Int((left / 60).rounded())) min left")
                } else {
                    self?.liveInfo = "estimating time…"
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        var codes: [Int32] = []
        await withTaskGroup(of: [Int32].self) { group in
            for w in 0..<n {
                let decode = w < hwParts ? ["-hwaccel", "videotoolbox"] : ["-threads", "2"]
                group.addTask {
                    var mine: [Int32] = []
                    while let i = line.take() {
                        if await self.cancelled { break }
                        let counter = done[i]
                        let code = await self.runTracked(ff, ["-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1"] + decode + allJobs[i]) { s in counter.seconds = s }
                        mine.append(code)
                        if code != 0 { break }
                    }
                    return mine
                }
            }
            for await c in group { codes.append(contentsOf: c) }
        }
        poll.cancel()
        extraProcesses = []
        if cancelled || codes.count != pieces || codes.contains(where: { $0 != 0 }) { return nil }

        // Join the parts (each told its exact length so the timing never drifts) and add the original sound.
        liveInfo = "joining parts…"
        let list = work.appendingPathComponent("parts.txt")
        let text = parts.map { "file '\($0.0.path.replacingOccurrences(of: "'", with: "'\\''"))'\nduration \(String(format: "%.3f", $0.1))" }
            .joined(separator: "\n")
        try? text.write(to: list, atomically: true, encoding: .utf8)
        let out = outputURL(for: src, ext: "mp4")
        var args = ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", list.path]
        if start > 0 { args += ["-ss", String(format: "%.3f", start)] }
        args += ["-t", String(format: "%.3f", mediaLen), "-i", src.path,
                 "-map", "0:v:0", "-map", "1:a:0?", "-c:v", "copy"] + (encoder.contains("hevc_videotoolbox") ? ["-tag:v", "hvc1"] : []) + [
                 ] + (abs(sp - 1) > 0.001 ? ["-af", String(format: "atempo=%.4f", sp)] : []) + [
                 "-c:a", "aac", "-b:a", audio,
                 "-movflags", "+faststart", out.path]
        let code = await run(ff, args)
        progress = 1
        if code != 0 || cancelled { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    private func saveFast(src: URL, ff: URL, rect: CGRect) async -> URL? {
        let out = outputURL(for: src, ext: "mp4")
        let look = lookFilter(rect), sp = speed
        let cropIt = look != nil || abs(sp - 1) > 0.001, trimIt = isTrimmed
        let start = trimStart, length = trimEnd - trimStart
        func args(_ encoder: [String], decode: [String] = []) -> [String] {
            var a = ["-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1"] + decode
            if trimIt && start > 0 { a += ["-ss", String(format: "%.3f", start)] }   // exact when re-encoding
            if trimIt { a += ["-t", String(format: "%.3f", length)] }   // before -i: limits what's read
            a += ["-i", src.path]
            a += ["-map", "0:v:0", "-map", "0:a?"]
            if cropIt {
                // Change-only encoding: frames identical to the previous one (inside the crop) are not
                // re-encoded; the previous frame just stays on screen longer. At least one frame per second is kept.
                a += ["-vf", (look.map { $0 + "," } ?? "") + "mpdecimate=hi=256:lo=128:frac=0.1:max=30"
                      + (abs(sp - 1) > 0.001 ? String(format: ",setpts=PTS/%.4f", sp) : ""), "-fps_mode", "vfr"]
                if abs(sp - 1) > 0.001 { a += ["-af", String(format: "atempo=%.4f", sp)] }
            }
            return a + encoder + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out.path]
        }
        // Fastest first: hardware decode + hardware encode tuned for speed. Software only as a last resort.
        let attempts: [(String, [String], [String])] = [
            ("Mac hardware decode + encode", ["-hwaccel", "videotoolbox"], ["-c:v", "h264_videotoolbox", "-prio_speed", "1", "-q:v", "65"]),
            ("Mac hardware encode", [], ["-c:v", "h264_videotoolbox", "-q:v", "65", "-allow_sw", "1"]),
            ("Mac hardware encode (bitrate)", [], ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-allow_sw", "1"]),
            ("software encoder (slow)", [], ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]),
        ]
        var code: Int32 = -1
        for (label, decode, enc) in attempts {
            fastEncoder = label
            code = await run(ff, args(enc, decode: decode), trackProgress: true)
            if code == 0 || cancelled { break }
        }
        if code != 0 || cancelled { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    private func run(_ exe: URL, _ args: [String], trackProgress: Bool = false) async -> Int32 {
        let total = (isTrimmed ? trimEnd - trimStart : duration) / speed
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            final class Box: @unchecked Sendable { var done = 0.0; var fps = 0.0; let started = Date() }
            let box = Box()
            let splitter = LineSplitter { [weak self] line in
                guard trackProgress, total > 0 else { return }
                if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)) {
                    box.done = us / 1_000_000
                    let frac = min(max(box.done / total, 0), 1)
                    Task { @MainActor in self?.progress = frac }
                } else if line.hasPrefix("fps="), let f = Double(line.dropFirst(4)) {
                    box.fps = f
                } else if line.hasPrefix("speed="), let sp = Double(line.dropFirst(6).replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)), sp > 0 {
                    let left = max(0, total - box.done) / sp
                    let eta = left < 60 ? "under a minute left" : "about \(Int((left / 60).rounded())) min left"
                    let text = Date().timeIntervalSince(box.started) < 20 ? "estimating time…"
                        : String(format: "%.1f× · %.0f fps · ", sp, box.fps) + eta
                    Task { @MainActor in self?.liveInfo = text }
                }
            }
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { splitter.feed(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run(); process = p } catch { cont.resume(returning: -1) }
        }
    }
}

// MARK: - View

struct CropView: View {
    @StateObject private var model = CropModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Open Video…") { model.choose() }.disabled(model.busy)
                if let u = model.url {
                    Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Shape", selection: $model.aspect) {
                    ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 170)
                .disabled(model.url == nil || model.busy)
                Button("Add Blur") { model.addBlur() }
                    .disabled(model.url == nil || model.busy)
                    .help("Adds a box that blurs that part of the picture, e.g. a name, a face or a patient ID. Drag it into place; × removes it.")
                Button("Reset") { model.reset() }.disabled(model.url == nil || model.busy)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                if let img = model.frame, model.videoSize.width > 0 {
                    CropCanvas(model: model, image: img)
                        .padding(14)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "crop").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Drop a video here, or click Open Video…").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 340)
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first, !model.busy else { return false }
                Task { await model.open(u) }
                return true
            }

            if model.url != nil {
                HStack(spacing: 10) {
                    Text(timeString(model.time)).monospacedDigit().foregroundStyle(.secondary)
                    Slider(value: $model.time, in: 0...max(model.duration, 0.1))
                        .onChange(of: model.time) { _ in Task { await model.refreshFrame() } }
                    Text(timeString(model.duration)).monospacedDigit().foregroundStyle(.secondary)
                }
                TrimBar(start: model.trimStart, end: model.trimEnd, duration: model.duration, playhead: model.time)
                    .frame(height: 8)
                HStack(spacing: 10) {
                    Picker("Speed", selection: $model.speed) {
                        Text("1×").tag(1.0); Text("1.25×").tag(1.25); Text("1.5×").tag(1.5)
                        Text("1.75×").tag(1.75); Text("2×").tag(2.0)
                    }
                    .frame(width: 130)
                    .disabled(model.busy)
                    .help("Saves the video faster, with voices kept at their normal pitch.")
                    Button("Set Start") { model.setStart() }.disabled(model.busy)
                    Button("Set End") { model.setEnd() }.disabled(model.busy)
                    if model.isTrimmed {
                        Button("Clear Trim") { model.clearTrim() }.disabled(model.busy)
                        Text("Keep \(timeString(model.trimStart)) – \(timeString(model.trimEnd))  (\(timeString(model.trimEnd - model.trimStart)))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text("To trim: move the slider, then Set Start / Set End.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.blurs.isEmpty {
                    Text("Blur boxes stay in the same spot for the whole video; they don't follow a face that moves.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.isCropped || model.hasEffects
                     ? "Saving rebuilds the video: cropped-out and blurred areas are permanently removed, and cuts are exact. This takes a few minutes for long videos."
                     : "Trim only: saves in seconds. The cut starts at the nearest keyframe, up to a few seconds early.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    let r = model.pixelRect
                    Text(model.isCropped ? "\(Int(r.width)) × \(Int(r.height))" : "Full frame").monospacedDigit()
                    Spacer()
                    if model.busy {
                        if let p = model.progress {
                            ProgressView(value: p).frame(width: 160)
                            Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                            if let info = model.liveInfo { Text(info).monospacedDigit().foregroundStyle(.secondary) }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel") { model.cancel() }
                    } else {
                        Button("Compress & Save") { model.save(.fast, compress: true) }
                            .alert("This video can't be made any smaller", isPresented: $model.offerPlainSave) {
                                Button("Save Without Compressing") { model.save(.fast) }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("It's already compressed about as far as it can go without visible loss. Save your crop and trim anyway, without compressing?")
                            }
                            .help("Saves your crop and trim as the smallest file that still looks the same (HEVC).")
                        Button("Save") { model.save(.fast) }
                            .keyboardShortcut(.defaultAction)
                            .help("Rebuilds the video with your Mac's video hardware: the cropped area is permanently removed and trims are exact.")
                    }
                }
                .controlSize(.large)

                if let s = model.status {
                    HStack {
                        Text(s).font(.callout).foregroundStyle(.secondary)
                        if let f = model.savedFile {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private func timeString(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The video frame with the crop box, darkened outside, and drag handles.
struct CropCanvas: View {
    @ObservedObject var model: CropModel
    let image: CGImage
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(container: geo.size, content: model.videoSize)
            let box = CGRect(x: fit.minX + model.crop.minX * fit.width,
                             y: fit.minY + model.crop.minY * fit.height,
                             width: model.crop.width * fit.width,
                             height: model.crop.height * fit.height)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)

                // Blur boxes: a live preview of the blur, plus handles to move and resize, and × to remove.
                ForEach(model.blurs.indices, id: \.self) { i in
                    let b = model.blurs[i]
                    let bb = CGRect(x: fit.minX + b.minX * fit.width, y: fit.minY + b.minY * fit.height,
                                    width: b.width * fit.width, height: b.height * fit.height)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: fit.width, height: fit.height)
                            .blur(radius: 14, opaque: true)
                            .offset(x: fit.minX, y: fit.minY)
                    }
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: bb.width, height: bb.height).offset(x: bb.minX, y: bb.minY)
                    }
                    .allowsHitTesting(false)
                }

                // Darken everything outside the crop box.
                Path { p in
                    p.addRect(fit)
                    p.addRect(box)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // Box, thirds guide, and the area you drag to move it.
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.001))
                    Path { p in
                        for i in 1...2 {
                            let x = box.width * CGFloat(i) / 3, y = box.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: box.height))
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: box.width, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    Rectangle().stroke(Color.white, lineWidth: 2)
                }
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let start = dragStart ?? model.crop
                        dragStart = start
                        model.crop = model.moved(from: start, dx: v.translation.width / fit.width,
                                                 dy: v.translation.height / fit.height)
                    }
                    .onEnded { _ in dragStart = nil })
                .disabled(model.busy)

                ForEach(model.blurs.indices, id: \.self) { i in
                    let b = model.blurs[i]
                    let bb = CGRect(x: fit.minX + b.minX * fit.width, y: fit.minY + b.minY * fit.height,
                                    width: b.width * fit.width, height: b.height * fit.height)
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.001))
                        Rectangle().stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                    .frame(width: bb.width, height: bb.height)
                    .offset(x: bb.minX, y: bb.minY)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            guard i < model.blurs.count else { return }
                            let start = dragStart ?? model.blurs[i]
                            dragStart = start
                            model.blurs[i] = model.moved(from: start, dx: v.translation.width / fit.width,
                                                         dy: v.translation.height / fit.height)
                        }
                        .onEnded { _ in dragStart = nil })
                    .disabled(model.busy)
                    ForEach([CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { h in
                        Circle().fill(Color.orange)
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle().inset(by: -8))
                            .position(x: bb.minX + h.anchor.x * bb.width, y: bb.minY + h.anchor.y * bb.height)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    guard i < model.blurs.count else { return }
                                    let start = dragStart ?? model.blurs[i]
                                    dragStart = start
                                    model.blurs[i] = model.resizedFree(from: start, handle: h,
                                                                       dx: v.translation.width / fit.width,
                                                                       dy: v.translation.height / fit.height)
                                }
                                .onEnded { _ in dragStart = nil })
                            .disabled(model.busy)
                    }
                    Button { if i < model.blurs.count { model.blurs.remove(at: i) } } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                            .foregroundStyle(.white, .orange)
                    }
                    .buttonStyle(.plain)
                    .position(x: bb.maxX + 10, y: bb.minY - 10)
                    .disabled(model.busy)
                }

                ForEach(CropHandle.allCases, id: \.self) { h in
                    let size: CGFloat = h.isCorner ? 16 : 12
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: size, height: size)
                        .contentShape(Rectangle().inset(by: -8))
                        .position(x: box.minX + h.anchor.x * box.width, y: box.minY + h.anchor.y * box.height)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let start = dragStart ?? model.crop
                                dragStart = start
                                model.crop = model.resized(from: start, handle: h,
                                                           dx: v.translation.width / fit.width,
                                                           dy: v.translation.height / fit.height)
                            }
                            .onEnded { _ in dragStart = nil })
                        .disabled(model.busy)
                }
            }
        }
    }

    private func fittedRect(container: CGSize, content: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let w = content.width * scale, h = content.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

/// The kept part of the video, shown under the time slider.
struct TrimBar: View {
    let start: Double, end: Double, duration: Double, playhead: Double

    var body: some View {
        GeometryReader { g in
            let d = max(duration, 0.001)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(2, g.size.width * CGFloat((end - start) / d)))
                    .offset(x: g.size.width * CGFloat(start / d))
                Rectangle().fill(Color.primary).frame(width: 2)
                    .offset(x: g.size.width * CGFloat(min(playhead, d) / d) - 1)
            }
        }
    }
}


/// Compress tab: one video in, the smallest file that still looks the same out.
struct CompressView: View {
    @StateObject private var model = CropModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button("Open Video…") { model.choose() }.disabled(model.busy)
                if let u = model.url {
                    Text(u.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                if let img = model.frame {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(14)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Drop a video here, or click Open Video…").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 300)
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first, !model.busy else { return false }
                Task { await model.open(u) }
                return true
            }
            if let u = model.url {
                Text(details(u)).monospacedDigit().foregroundStyle(.secondary)
                if let warn = alreadyCompact(u) {
                    Label(warn, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                Text("Makes the smallest file that still looks the same. A few quality levels are tested on samples first (about 20–30 seconds), then the whole video is saved in HEVC using your Mac's video hardware. HEVC plays on Apple devices, current Chrome and Edge, and Android; some older Windows PCs need a free add-on.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Spacer()
                    if model.busy {
                        if let p = model.progress {
                            ProgressView(value: p).frame(width: 160)
                            Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let info = model.liveInfo { Text(info).monospacedDigit().foregroundStyle(.secondary) }
                        Button("Cancel") { model.cancel() }
                    } else {
                        if alreadyCompact(u) != nil {
                            Button("Try Anyway") { model.save(.fast, compress: true) }
                        } else {
                            Button("Compress") { model.save(.fast, compress: true) }.keyboardShortcut(.defaultAction)
                        }
                    }
                }
                .controlSize(.large)
                if let s = model.status {
                    HStack {
                        Text(s).font(.callout).foregroundStyle(.secondary)
                        if let f = model.savedFile {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }.controlSize(.small)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    /// Videos stored with very little data per pixel can't get smaller without looking worse:
    /// say so before the user waits for anything.
    private func alreadyCompact(_ u: URL) -> String? {
        let bytes = Double((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let px = model.videoSize.width * model.videoSize.height
        guard model.duration > 0, px > 0 else { return nil }
        let rate = bytes * 8 / model.duration
        let bitsPerPixel = rate / (Double(px) * model.fps)
        guard bitsPerPixel < 0.04 else { return nil }
        return String(format: "This video is already very compact (%.1f Mbps), so compressing it probably won't make it smaller without visible loss. It's not worth trying. Compress works best on large originals: iPhone videos, screen recordings, local Zoom recordings.", rate / 1e6)
    }

    private func details(_ u: URL) -> String {
        let mb = Double((try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576
        let t = Int(model.duration)
        let len = t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
        return "\(Int(model.videoSize.width)) × \(Int(model.videoSize.height)) · \(len) · \(String(format: "%.0f", mb)) MB"
    }
}
