// Images → GIF tab: pick or drop images, put them in order, choose timing and size, make a looping GIF.

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ImagesGIFModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let thumb: NSImage?
    }

    enum Shape: String, CaseIterable, Identifiable {
        case first = "Like first image", square = "Square", wide = "16:9", tall = "9:16", portrait = "4:5"
        var id: String { rawValue }
        func ratio(first: CGSize) -> CGFloat {   // width / height
            switch self {
            case .first: return first.height > 0 ? first.width / first.height : 1
            case .square: return 1
            case .wide: return 16 / 9
            case .tall: return 9 / 16
            case .portrait: return 4 / 5
            }
        }
    }

    @Published var items: [Item] = []
    @Published var secondsEach: Double = 1.0
    @Published var width = 640
    @Published var shape: Shape = .first
    @Published var fill = false                 // false: show whole image (bars), true: fill and trim edges
    @Published var background: Color = .white
    @Published var fade = false
    @Published var busy = false
    @Published var progress: Double?
    @Published var status: String?
    @Published var savedFile: URL?
    private var process: Process?
    private var cancelled = false

    static let types: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .webP, .bmp, .image]

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for u in sorted where Self.isImage(u) {
            items.append(Item(url: u, thumb: Self.load(u, maxSide: 160).map { NSImage(cgImage: $0, size: .zero) }))
        }
        status = nil; savedFile = nil
    }

    static func isImage(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .image)
    }

    func move(_ from: IndexSet, _ to: Int) { items.move(fromOffsets: from, toOffset: to) }
    func remove(_ item: Item) { items.removeAll { $0.id == item.id } }
    func clear() { items = []; status = nil; savedFile = nil }

    /// Loads an image the right way up (phone photos store rotation separately), at most `maxSide` pixels.
    nonisolated static func load(_ url: URL, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    func cancel() { cancelled = true; process?.terminate() }

    func make() {
        guard !items.isEmpty, !busy else { return }
        guard let ff = Tools.find("ffmpeg") else {
            status = "ffmpeg isn't installed yet. Open the Download tab once so Pare Reels can fetch it."
            return
        }
        busy = true; cancelled = false; savedFile = nil; progress = 0
        status = "Making GIF…"
        let urls = items.map(\.url)
        let secs = secondsEach, fill = fill, fade = fade && items.count > 1
        let bg = NSColor(background).usingColorSpace(.sRGB) ?? .white
        let started = Date()
        let shape = shape, chosenWidth = width
        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("pare-gif-\(UUID().uuidString)")
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }

            // Canvas size from the chosen shape (even numbers, as video tools prefer).
            let firstSize: CGSize = {
                guard let i = Self.load(urls[0], maxSide: 4000) else { return CGSize(width: 4, height: 3) }
                return CGSize(width: i.width, height: i.height)
            }()
            let ratio = shape.ratio(first: firstSize)
            var W = chosenWidth > 0 ? chosenWidth : Int(firstSize.width)
            var H = Int((CGFloat(W) / ratio).rounded())
            if chosenWidth == 0, H > 2000 { H = 2000; W = Int((CGFloat(H) * ratio).rounded()) }
            W -= W % 2; H -= H % 2
            W = max(W, 16); H = max(H, 16)

            // Draw each picture onto the canvas.
            func frame(_ img: CGImage?) -> CGImage? {
                guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                ctx.interpolationQuality = .high
                if let img {
                    let iw = CGFloat(img.width), ih = CGFloat(img.height)
                    let s = fill ? max(CGFloat(W) / iw, CGFloat(H) / ih) : min(CGFloat(W) / iw, CGFloat(H) / ih)
                    let dw = iw * s, dh = ih * s
                    ctx.draw(img, in: CGRect(x: (CGFloat(W) - dw) / 2, y: (CGFloat(H) - dh) / 2, width: dw, height: dh))
                }
                return ctx.makeImage()
            }
            func blend(_ a: CGImage, _ b: CGImage, _ t: CGFloat) -> CGImage? {
                guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                let r = CGRect(x: 0, y: 0, width: W, height: H)
                ctx.draw(a, in: r); ctx.setAlpha(t); ctx.draw(b, in: r)
                return ctx.makeImage()
            }
            func save(_ img: CGImage, _ name: String) -> Bool {
                let u = work.appendingPathComponent(name)
                guard let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
                CGImageDestinationAddImage(d, img, nil)
                return CGImageDestinationFinalize(d)
            }

            let maxSide = max(W, H) * 2
            var frames: [CGImage] = []
            for (i, u) in urls.enumerated() {
                if let f = frame(Self.load(u, maxSide: maxSide)) { frames.append(f) }
                let p = 0.6 * Double(i + 1) / Double(urls.count)
                await MainActor.run { self?.progress = p }
                if await MainActor.run(body: { self?.cancelled ?? true }) { return }
            }
            guard !frames.isEmpty else {
                await MainActor.run { self?.finish(nil, started, "None of those images could be opened.") }
                return
            }

            // A list of frames and how long each shows; fades add a few in-between frames.
            var list = ""; var n = 0
            let fadeSteps = 6, fadeTime = min(0.5, secs * 0.4)
            for (i, f) in frames.enumerated() {
                let hold = fade ? max(0.05, secs - fadeTime) : secs
                let name = String(format: "f%05d.png", n); n += 1
                guard save(f, name) else { continue }
                list += "file '\(name)'\nduration \(String(format: "%.3f", hold))\n"
                if fade {
                    let next = frames[(i + 1) % frames.count]   // last image fades back into the first, for a smooth loop
                    for k in 1...fadeSteps {
                        guard let b = blend(f, next, CGFloat(k) / CGFloat(fadeSteps + 1)) else { continue }
                        let bn = String(format: "f%05d.png", n); n += 1
                        if save(b, bn) { list += "file '\(bn)'\nduration \(String(format: "%.3f", fadeTime / Double(fadeSteps)))\n" }
                    }
                }
            }
            // The concat list needs the last file repeated so its duration counts.
            if let last = list.split(separator: "\n").last(where: { $0.hasPrefix("file ") }) { list += "\(last)\n" }
            let listURL = work.appendingPathComponent("list.txt")
            try? list.write(to: listURL, atomically: true, encoding: .utf8)

            var dir = urls[0].deletingLastPathComponent()
            if !fm.isWritableFile(atPath: dir.path) { dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
            let base = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Images"
            let out = await MainActor.run { DownloadModel.uniqueURL(in: dir, name: base + " (GIF)", ext: "gif") }

            let args = ["-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listURL.path,
                        "-filter_complex", "[0:v]split[a][b];[a]palettegen=stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a",
                        "-fps_mode", "vfr", "-loop", "0", out.path]
            let p = Process()
            p.executableURL = ff
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            await MainActor.run { self?.process = p; self?.progress = 0.8 }
            let code: Int32 = await withCheckedContinuation { c in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { c.resume(returning: -1) }
            }
            await MainActor.run {
                if code == 0, !(self?.cancelled ?? true) {
                    self?.finish(out, started, nil)
                } else {
                    try? fm.removeItem(at: out)
                    self?.finish(nil, started, (self?.cancelled ?? false) ? "Cancelled." : "Making the GIF failed.")
                }
            }
        }
    }

    private func finish(_ out: URL?, _ started: Date, _ error: String?) {
        busy = false; progress = nil; process = nil
        if let out {
            savedFile = out
            let mb = Double((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576
            status = "Saved “\(out.lastPathComponent)” in \(CropModel.duration(Date().timeIntervalSince(started))) · \(String(format: mb < 10 ? "%.1f" : "%.0f", mb)) MB."
        } else {
            status = error
        }
    }
}

struct ImagesToGIFView: View {
    @StateObject private var model = ImagesGIFModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button("Add Images…") { model.choose() }.disabled(model.busy)
                if !model.items.isEmpty {
                    Text("\(model.items.count) image\(model.items.count == 1 ? "" : "s") · drag to change the order")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { model.clear() }.disabled(model.items.isEmpty || model.busy)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08))
                if model.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Drop images here, or click Add Images…").foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                            HStack(spacing: 12) {
                                Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                                if let t = item.thumb {
                                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fit).frame(width: 64, height: 48)
                                } else {
                                    Image(systemName: "photo").frame(width: 64, height: 48)
                                }
                                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { model.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .disabled(model.busy)
                            }
                        }
                        .onMove { model.move($0, $1) }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minHeight: 300)
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.busy else { return false }
                model.add(urls)
                return true
            }

            HStack(spacing: 14) {
                Text("Each image")
                Slider(value: $model.secondsEach, in: 0.1...5, step: 0.1).frame(width: 140)
                Text(String(format: "%.1f s", model.secondsEach)).monospacedDigit().frame(width: 44, alignment: .leading)
                Toggle("Fade between images", isOn: $model.fade)
            }
            .disabled(model.busy)
            HStack(spacing: 14) {
                Picker("Shape", selection: $model.shape) {
                    ForEach(ImagesGIFModel.Shape.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 220)
                Picker("Size", selection: $model.width) {
                    Text("Small (480)").tag(480); Text("Medium (640)").tag(640)
                    Text("Large (800)").tag(800); Text("Full size").tag(0)
                }
                .frame(width: 190)
                Picker("Fit", selection: $model.fill) {
                    Text("Whole image").tag(false); Text("Fill the frame").tag(true)
                }
                .frame(width: 180)
                if !model.fill { ColorPicker("Bars", selection: $model.background) }
            }
            .disabled(model.busy)

            HStack(spacing: 12) {
                if model.items.count > 1 {
                    let total = model.secondsEach * Double(model.items.count)
                    Text(String(format: "About %.0f seconds per loop. It loops forever.", total))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy {
                    if let p = model.progress { ProgressView(value: p).frame(width: 160) }
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Make GIF") { model.make() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.items.isEmpty)
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
        .padding(20)
    }
}
