// Asks AVFoundation (the engine QuickTime, Photos and Safari use) what it shows for each file.
import AVFoundation
import AppKit

func save(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let files = CommandLine.arguments.dropFirst()
let sem = DispatchSemaphore(value: 0)
Task {
    for f in files {
        let asset = AVURLAsset(url: URL(fileURLWithPath: f))
        do {
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let natural = try await track.load(.naturalSize)
            let fds = try await track.load(.formatDescriptions)
            let dims = CMVideoFormatDescriptionGetDimensions(fds[0])
            let clean = CMVideoFormatDescriptionGetCleanAperture(fds[0], originIsAtTopLeft: true)
            for mode in [AVAssetImageGenerator.ApertureMode.cleanAperture, .productionAperture, .encodedPixels] {
                let g = AVAssetImageGenerator(asset: asset)
                g.apertureMode = mode
                g.appliesPreferredTrackTransform = true
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                let (img, _) = try await g.image(at: CMTime(seconds: 1, preferredTimescale: 600))
                let tag = mode == .cleanAperture ? "clean" : mode == .productionAperture ? "production" : "encoded"
                save(img, "\(f).\(tag).png")
                print("RESULT \(f) mode=\(tag) natural=\(Int(natural.width))x\(Int(natural.height)) fmtdims=\(dims.width)x\(dims.height) clap=\(clean) image=\(img.width)x\(img.height)")
            }
            // What the hardware decoder actually hands over (AVAssetReader).
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(out); reader.startReading()
            if let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
                let att = CVBufferCopyAttachment(pb, kCVImageBufferCleanApertureKey, nil)
                print("RESULT \(f) reader buffer=\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) cleanApertureAttachment=\(String(describing: att))")
            }
        } catch { print("RESULT \(f) ERROR \(error)") }
    }
    sem.signal()
}
sem.wait()
