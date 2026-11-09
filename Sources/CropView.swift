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
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1)   // 0...1 of the frame
    @Published var aspect: CropAspect = .free { didSet { applyAspect() } }
    @Published var codec = ""
    @Published var rotated = false
    @Published var busy = false
    @Published var progress: Double?
    @Published var status: String?
    @Published var savedFile: URL?

    private var generator: AVAssetImageGenerator?
    private var frameRequest = 0
    private var process: Process?
    private var cancelled = false

    var canInstant: Bool { (codec == "h264" || codec == "hevc") && !rotated }

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
        applyAspect()
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
        applyAspect()
    }

    // MARK: Saving

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    private func outputURL(for src: URL, ext: String) -> URL {
        var dir = src.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: dir.path) {
            dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        let base = src.deletingPathExtension().lastPathComponent + " (cropped)"
        return DownloadModel.uniqueURL(in: dir, name: base, ext: ext)
    }

    func save(instant: Bool) {
        guard let src = url, !busy else { return }
        guard let ff = Tools.find("ffmpeg") else {
            status = "ffmpeg isn't installed yet. Open the Download tab once so Pare Reels can fetch it."
            return
        }
        busy = true; cancelled = false; savedFile = nil
        progress = instant ? nil : 0
        status = instant ? "Saving (instant)…" : "Saving (fast re-encode)…"
        let rect = pixelRect
        Task {
            let result = instant ? await saveInstant(src: src, ff: ff, rect: rect)
                                 : await saveFast(src: src, ff: ff, rect: rect)
            busy = false
            progress = nil
            if cancelled {
                status = "Cancelled."
            } else if let out = result {
                savedFile = out
                status = "Saved “\(out.lastPathComponent)”."
            } else {
                status = instant ? "Instant save didn't work for this file. Try Fast instead." : "Saving failed. See details in the Download tab's Log."
            }
        }
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

        // Pass 1: change the crop inside the video stream (no re-encoding).
        guard await run(ff, ["-y", "-loglevel", "error", "-i", src.path, "-map", "0:v:0", "-map", "0:a?",
                             "-c", "copy", "-bsf:v", bsf, tmp.path]) == 0, !cancelled else { return nil }
        // Pass 2: rewrite the file so its stated size matches the new picture.
        var args = ["-y", "-loglevel", "error", "-i", tmp.path, "-map", "0", "-c", "copy"]
        if codec == "hevc" { args += ["-tag:v", "hvc1"] }
        args += ["-movflags", "+faststart", out.path]
        guard await run(ff, args) == 0, !cancelled else { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    private func saveFast(src: URL, ff: URL, rect: CGRect) async -> URL? {
        let out = outputURL(for: src, ext: "mp4")
        let filter = "crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))"
        func args(_ encoder: [String]) -> [String] {
            ["-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1",
             "-i", src.path, "-map", "0:v:0", "-map", "0:a?", "-vf", filter]
            + encoder + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", out.path]
        }
        // Mac hardware encoder first; the software encoder only if that's unavailable.
        var code = await run(ff, args(["-c:v", "h264_videotoolbox", "-q:v", "65", "-allow_sw", "1"]), trackProgress: true)
        if code != 0, !cancelled {
            code = await run(ff, args(["-c:v", "h264_videotoolbox", "-b:v", "8M", "-allow_sw", "1"]), trackProgress: true)
        }
        if code != 0, !cancelled {
            code = await run(ff, args(["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"]), trackProgress: true)
        }
        if code != 0 || cancelled { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    private func run(_ exe: URL, _ args: [String], trackProgress: Bool = false) async -> Int32 {
        let total = duration
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            let splitter = LineSplitter { [weak self] line in
                guard trackProgress, line.hasPrefix("out_time_us="), total > 0,
                      let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                let frac = min(max(us / 1_000_000 / total, 0), 1)
                Task { @MainActor in self?.progress = frac }
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
                Text("Drag the slider to check the crop works for the whole video.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    let r = model.pixelRect
                    Text("\(Int(r.width)) × \(Int(r.height))").monospacedDigit()
                    Spacer()
                    if model.busy {
                        if let p = model.progress {
                            ProgressView(value: p).frame(width: 160)
                            Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel") { model.cancel() }
                    } else {
                        Button("Save — Fast") { model.save(instant: false) }
                            .help("Re-encodes with your Mac's video hardware. Works everywhere, smaller file. A few minutes for an hour of video.")
                        Button("Save — Instant") { model.save(instant: true) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canInstant)
                            .help(model.canInstant
                                  ? "No re-encoding: done in seconds with no quality loss."
                                  : "Not available for this video (rotated, or not H.264/HEVC). Use Fast.")
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
