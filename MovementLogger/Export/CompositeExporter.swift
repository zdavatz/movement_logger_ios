import Foundation
import AVFoundation
import UIKit

/// V-stack composite: source video on top, four data panels below
/// (speed, pitch, height, GPS track), exported as H.264 .mov.
///
/// Uses `AVAssetExportSession` + `AVVideoCompositionCoreAnimationTool` —
/// the standard Apple-managed pipeline. The per-frame logic runs on the
/// OS's optimized parallel rendering path (multiple frames in flight,
/// hardware H.264 encode), so for a 39-s 1080×3200 export this completes
/// roughly in real-time (~30-60 s end-to-end) instead of taking minutes
/// like the hand-rolled `AVAssetReader` + `AVAssetWriter` loop.
///
/// Geometry trick: `videoLayer.frame == parentLayer.frame == renderSize`.
/// With the layer instruction transform placing the source frame in the
/// TOP region of `renderSize` (and the rest of the render output being
/// black), the videoLayer fills the whole parent — no letterbox gap
/// inside it. Panel `CALayer`s are siblings of `videoLayer` positioned
/// at the bottom of the parent (Y-up Quartz: low Y); since they're added
/// AFTER `videoLayer`, they're composited ON TOP, obscuring the black
/// bottom of the video render.
enum CompositeExportError: Error, LocalizedError {
    case noVideoTrack
    case noVideoCreationTime
    case exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .noVideoTrack:        return "source video has no video track"
        case .noVideoCreationTime: return "video has no creation_time — can't align panels"
        case .exportFailed(let m): return "export failed: \(m)"
        }
    }
}

struct CompositeExportInputs {
    let sourceVideoURL: URL
    let videoCreationMs: Int64
    let speedSmoothedKmh: [Double]
    let gpsAbsTimesMs: [Int64]
    let pitchDeg: [Double]
    let sensorAbsTimesMs: [Int64]
    let baroHeightM: [Double]
    let fusedHeightM: [Double]
    let gpsRows: [GpsRow]
}

enum CompositeExporter {

    private static let panelHeight: CGFloat = 320
    private static let panelCount: Int = 4

    static func export(
        _ inputs: CompositeExportInputs,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // ----- Load source asset
        let asset = AVURLAsset(url: inputs.sourceVideoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw CompositeExportError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)

        // Bounding-rect rotation gives the displayed (post-transform) size.
        let displayed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let videoW = abs(displayed.width).rounded()
        let videoH = abs(displayed.height).rounded()

        let outputW = videoW
        let panelStackH = panelHeight * CGFloat(panelCount)
        let outputH = videoH + panelStackH
        let outputSize = CGSize(width: outputW, height: outputH)
        let panelSize = CGSize(width: outputW, height: panelHeight)

        progress(0.001)

        // ----- Build the composition (source video + audio passthrough)
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw CompositeExportError.exportFailed("could not add video track") }
        try compVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero
        )
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero
            )
        }

        // ----- Layer instruction transform: orient source into TOP region of renderSize
        // preferredTransform usually rotates AND translates so the result lands in
        // the positive quadrant — but in case the translation isn't quite right, add
        // a correction so the rotated frame starts at (0, 0) of the render space.
        var layerXform = preferredTransform
        let rotated = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        layerXform = layerXform.concatenating(CGAffineTransform(
            translationX: -rotated.origin.x, y: -rotated.origin.y
        ))

        // ----- Pre-render static panel content (4 CGImages, scale=1)
        let panelImages: [CGImage] = (0..<panelCount).compactMap { i in
            renderPanelImage(index: i, size: panelSize, inputs: inputs)
        }

        // ----- CALayer hierarchy. AVF uses Y-UP Quartz convention here.
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        parentLayer.backgroundColor = UIColor.black.cgColor

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame  // FULL parent — no inner letterbox
        parentLayer.addSublayer(videoLayer)

        // Panel layers stacked at the BOTTOM of the canvas in Y-up Quartz
        // (i.e. the lower-Y region) so they appear at the bottom of the
        // displayed (Y-down) screen, just below the video.
        let durationS = CMTimeGetSeconds(duration)
        for i in 0..<panelImages.count {
            let panel = CALayer()
            // In Y-up Quartz: panel 0 (top of panel stack) is at the HIGH-Y
            // side of the panel area, i.e. just below the video.
            let yQuartz = CGFloat(panelCount - 1 - i) * panelHeight
            panel.frame = CGRect(origin: CGPoint(x: 0, y: yQuartz), size: panelSize)
            // The panel images are rendered top-down (UIKit). Without flipping
            // they'd appear upside-down in Y-up Quartz, so set isGeometryFlipped.
            panel.isGeometryFlipped = true
            panel.contents = panelImages[i]
            panel.contentsGravity = .resize

            // Cursor: vertical red line (panels 0..2) or moving dot (panel 3).
            if i < 3 {
                let cursor = CAShapeLayer()
                cursor.frame = CGRect(origin: .zero, size: panelSize)
                cursor.lineWidth = 4
                cursor.strokeColor = UIColor.systemRed.cgColor
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: panelSize.height))
                cursor.path = path

                let (values, keyTimes) = sweepCursorValues(
                    panelIndex: i, durationS: durationS,
                    panelWidth: outputW, inputs: inputs
                )
                let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
                anim.values = values
                anim.keyTimes = keyTimes.map { NSNumber(value: $0) }
                anim.duration = max(durationS, 0.001)
                anim.beginTime = AVCoreAnimationBeginTimeAtZero
                anim.fillMode = .forwards
                anim.isRemovedOnCompletion = false
                cursor.add(anim, forKey: "sweep")
                panel.addSublayer(cursor)
            } else {
                let dotR: CGFloat = 14
                let dot = CAShapeLayer()
                dot.frame = CGRect(x: -dotR, y: -dotR, width: dotR * 2, height: dotR * 2)
                dot.path = CGPath(
                    ellipseIn: CGRect(x: 0, y: 0, width: dotR * 2, height: dotR * 2),
                    transform: nil
                )
                dot.fillColor = UIColor.systemRed.cgColor

                let (xs, ys, keyTimes) = gpsDotValues(
                    durationS: durationS, panelSize: panelSize, inputs: inputs
                )
                let anim = CAKeyframeAnimation(keyPath: "position")
                anim.values = zip(xs, ys).map { x, y in
                    NSValue(cgPoint: CGPoint(x: x, y: y))
                }
                anim.keyTimes = keyTimes.map { NSNumber(value: $0) }
                anim.duration = max(durationS, 0.001)
                anim.beginTime = AVCoreAnimationBeginTimeAtZero
                anim.fillMode = .forwards
                anim.isRemovedOnCompletion = false
                dot.add(anim, forKey: "gps-dot")
                panel.addSublayer(dot)
            }

            // Live "now X.X" / "fused / baro" value labels — re-rendered per
            // output frame so the numbers track the cursor as the video plays.
            // Matches the Android Replay screen's top-left label stack.
            if let live = makeLiveValueLayer(
                panelIndex: i, panelSize: panelSize,
                durationS: durationS, inputs: inputs
            ) {
                panel.addSublayer(live)
            }

            // Add panel sublayers AFTER videoLayer so they're composited on top.
            parentLayer.addSublayer(panel)
        }

        // ----- Video composition
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = outputSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInst = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        layerInst.setTransform(layerXform, at: .zero)
        instruction.layerInstructions = [layerInst]
        videoComp.instructions = [instruction]

        // ----- Export
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw CompositeExportError.exportFailed("could not create export session")
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComp
        session.shouldOptimizeForNetworkUse = true

        // ----- Run export with progress polling
        let pollHandle = ProgressPoller(session: session, callback: progress)
        pollHandle.start()
        await session.export()
        pollHandle.stop()

        switch session.status {
        case .completed:
            progress(1.0)
        case .failed:
            throw CompositeExportError.exportFailed(session.error?.localizedDescription ?? "unknown")
        case .cancelled:
            throw CompositeExportError.exportFailed("cancelled")
        default:
            throw CompositeExportError.exportFailed("status \(session.status.rawValue)")
        }
    }

    // -------------------------------------------------------------------------
    //  Progress polling helper. AVAssetExportSession reports progress via a
    //  property; we sample it on a background timer.
    // -------------------------------------------------------------------------

    private final class ProgressPoller: @unchecked Sendable {
        private let session: AVAssetExportSession
        private let callback: @Sendable (Double) -> Void
        private var task: Task<Void, Never>?

        init(session: AVAssetExportSession, callback: @escaping @Sendable (Double) -> Void) {
            self.session = session
            self.callback = callback
        }

        func start() {
            task = Task { [session, callback] in
                while !Task.isCancelled {
                    callback(max(0.001, Double(session.progress)))
                    if session.status == .completed || session.status == .failed
                        || session.status == .cancelled { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }
    }

    // -------------------------------------------------------------------------
    //  Static panel rendering (scale = 1 to avoid the 31 MP device-scale trap)
    // -------------------------------------------------------------------------

    private static func renderPanelImage(
        index: Int, size: CGSize, inputs: CompositeExportInputs
    ) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let img = renderer.image { ctx in
            let cg = ctx.cgContext
            UIColor.secondarySystemBackground.setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            let title: String
            switch index {
            case 0: title = "Speed (km/h)"
            case 1: title = "Pitch / Nasenwinkel (°)"
            case 2: title = "Height above water (m)"
            default: title = "GPS track"
            }
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: UIColor.label,
            ]
            title.draw(at: CGPoint(x: 16, y: 8), withAttributes: titleAttrs)

            // Bake the static label (max / ± / range) below where the dynamic
            // labels will be drawn by the LiveValueLayer at render time.
            // Layout: title at y=8, then dynamic lines starting at y=56, each
            // ~30 tall. Static label sits at the bottom of the stack.
            let staticLabel: String?
            let staticY: CGFloat
            let labelFont = UIFont.monospacedSystemFont(ofSize: 22, weight: .regular)
            let staticAttrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: UIColor.secondaryLabel,
            ]
            switch index {
            case 0:
                let maxV = max(inputs.speedSmoothedKmh.max() ?? 0, 5.0)
                staticLabel = String(format: "max %.1f", maxV)
                staticY = 90
            case 1:
                let pitch = inputs.pitchDeg
                let minV = pitch.min() ?? 0
                let maxV = pitch.max() ?? 0
                let absMax = max(abs(minV), abs(maxV), 5.0)
                staticLabel = String(format: "±%.0f°", absMax)
                staticY = 90
            case 2:
                var minV = Double.infinity
                var maxV = -Double.infinity
                for v in inputs.baroHeightM { if v < minV { minV = v }; if v > maxV { maxV = v } }
                for v in inputs.fusedHeightM { if v < minV { minV = v }; if v > maxV { maxV = v } }
                staticLabel = String(format: "range %+.2f .. %+.2f", minV, maxV)
                staticY = 120
            default:
                staticLabel = nil
                staticY = 0
            }
            if let s = staticLabel {
                s.draw(at: CGPoint(x: 16, y: staticY), withAttributes: staticAttrs)
            }

            let inset = UIEdgeInsets(top: 56, left: 16, bottom: 16, right: 16)
            let plot = CGRect(
                x: inset.left, y: inset.top,
                width: size.width - inset.left - inset.right,
                height: size.height - inset.top - inset.bottom
            )

            switch index {
            case 0: drawSpeedSeries(cg, plot: plot, smoothed: inputs.speedSmoothedKmh)
            case 1: drawPitchSeries(cg, plot: plot, pitch: inputs.pitchDeg)
            case 2: drawHeightSeries(cg, plot: plot, baro: inputs.baroHeightM, fused: inputs.fusedHeightM)
            default: drawGpsTrack(cg, plot: plot, rows: inputs.gpsRows)
            }
        }
        return img.cgImage
    }

    // -------------------------------------------------------------------------
    //  Live per-frame value labels via the "filmstrip" pattern.
    //
    //  AVVideoCompositionCoreAnimationTool's offline render pass doesn't
    //  honor custom `CALayer.display()` re-renders during animation —
    //  it snapshots the layer tree once and only animates standard
    //  CA-animatable properties (position, opacity, transform, contentsRect,
    //  etc.). So instead of mutating `contents` on every frame from
    //  display(), we pre-render every frame's text into a single tall
    //  CGImage (a "filmstrip", one frame per row, stacked top-down) and
    //  animate `contentsRect` through it with `calculationMode = .discrete`.
    //  `contentsRect` is a built-in animatable property the AVF render
    //  path honors.
    // -------------------------------------------------------------------------

    /// Build a CALayer for the given panel that shows live "now <value>"
    /// labels matching the Android Replay screen's top-left stack. Returns
    /// nil for the GPS panel (which only has the dot — no numeric labels).
    private static func makeLiveValueLayer(
        panelIndex: Int, panelSize: CGSize,
        durationS: Double, inputs: CompositeExportInputs
    ) -> CALayer? {
        // Update rate: 10 Hz is plenty for human-readable values (100 ms
        // refresh) and keeps the filmstrip image at a reasonable size.
        let updateHz: Double = 10.0
        let steps = max(2, Int((durationS * updateHz).rounded()))
        let videoCreation = inputs.videoCreationMs

        // Map each frame s ∈ 0..<steps to the nearest data-array index, using
        // the same time-mapping logic as the cursor sweep so labels and
        // cursor stay in lock-step.
        func indices(for times: [Int64], count: Int) -> [Int] {
            var out = [Int](repeating: 0, count: steps)
            guard count >= 1, !times.isEmpty else { return out }
            for s in 0..<steps {
                let t = Double(s) / Double(steps - 1)
                let videoTimeMs = Int64(t * durationS * 1000.0)
                let target = videoCreation + videoTimeMs
                let idx = nearestIndexByTime(times, target: target)
                out[s] = max(0, min(count - 1, idx))
            }
            return out
        }

        // Per-series resolved value arrays (length = steps).
        let valueArrays: [[Double]]
        let labelFormats: [String]
        let labelColors: [UIColor]

        switch panelIndex {
        case 0:
            let idxs = indices(for: inputs.gpsAbsTimesMs, count: inputs.speedSmoothedKmh.count)
            valueArrays = [idxs.map { inputs.speedSmoothedKmh[$0] }]
            labelFormats = ["now %.1f"]
            labelColors = [UIColor.label]
        case 1:
            let idxs = indices(for: inputs.sensorAbsTimesMs, count: inputs.pitchDeg.count)
            valueArrays = [idxs.map { inputs.pitchDeg[$0] }]
            labelFormats = ["now %+.1f°"]
            labelColors = [UIColor.label]
        case 2:
            let fIdxs = indices(for: inputs.sensorAbsTimesMs, count: inputs.fusedHeightM.count)
            let bIdxs = indices(for: inputs.sensorAbsTimesMs, count: inputs.baroHeightM.count)
            valueArrays = [
                fIdxs.map { inputs.fusedHeightM[$0] },
                bIdxs.map { inputs.baroHeightM[$0] },
            ]
            labelFormats = ["fused %+.2f m", "baro  %+.2f m"]
            labelColors = [UIColor.systemBlue, UIColor.secondaryLabel]
        default:
            return nil
        }

        let labelFont = UIFont.monospacedSystemFont(ofSize: 22, weight: .regular)
        let lineHeight: CGFloat = 30
        let lines = valueArrays.count
        let frameHeight = lineHeight * CGFloat(lines)
        let frameWidth = panelSize.width - 32

        // Render the filmstrip: each of `steps` frames is one row, stacked
        // top-down.
        let stripSize = CGSize(width: frameWidth, height: frameHeight * CGFloat(steps))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: stripSize, format: format)
        let stripImage = renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: stripSize))
            for s in 0..<steps {
                let yBase = CGFloat(s) * frameHeight
                for (j, vals) in valueArrays.enumerated() {
                    let v = vals[s]
                    let text = String(format: labelFormats[j], v)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: labelFont,
                        .foregroundColor: labelColors[j],
                    ]
                    (text as NSString).draw(
                        at: CGPoint(x: 0, y: yBase + CGFloat(j) * lineHeight),
                        withAttributes: attrs
                    )
                }
            }
        }

        // Layer is the size of ONE frame in the filmstrip — `contentsRect`
        // controls which slice of the strip is visible.
        let layer = CALayer()
        layer.contents = stripImage.cgImage
        layer.contentsGravity = .resize
        layer.frame = CGRect(x: 16, y: 56, width: frameWidth, height: frameHeight)
        layer.isOpaque = false
        // Start showing frame 0 of the strip.
        let frac = 1.0 / Double(steps)
        layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: frac)

        // Keyframe animation that snaps `contentsRect` to each frame in
        // turn. `.discrete` means no interpolation between frames — each
        // value holds until the next keyTime.
        let values = (0..<steps).map { s in
            NSValue(cgRect: CGRect(x: 0, y: Double(s) * frac, width: 1, height: frac))
        }
        let keyTimes = (0..<steps).map { NSNumber(value: Double($0) / Double(steps - 1)) }

        let anim = CAKeyframeAnimation(keyPath: "contentsRect")
        anim.values = values
        anim.keyTimes = keyTimes
        anim.calculationMode = .discrete
        anim.duration = max(durationS, 0.001)
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "values")

        return layer
    }

    private static func drawSpeedSeries(_ cg: CGContext, plot: CGRect, smoothed: [Double]) {
        let n = smoothed.count
        guard n >= 2 else { return }
        let maxV = max(smoothed.max() ?? 0, 5.0)
        cg.setStrokeColor(UIColor.systemBlue.cgColor)
        cg.setLineWidth(3)
        cg.beginPath()
        for i in 0..<n {
            let x = plot.minX + CGFloat(i) / CGFloat(n - 1) * plot.width
            let y = plot.maxY - CGFloat(smoothed[i] / maxV) * plot.height
            if i == 0 { cg.move(to: CGPoint(x: x, y: y)) }
            else      { cg.addLine(to: CGPoint(x: x, y: y)) }
        }
        cg.strokePath()
    }

    private static func drawPitchSeries(_ cg: CGContext, plot: CGRect, pitch: [Double]) {
        let n = pitch.count
        guard n >= 2 else { return }
        let minV = pitch.min() ?? 0
        let maxV = pitch.max() ?? 0
        let absMax = max(abs(minV), abs(maxV), 5.0)
        let zeroY = plot.midY
        cg.setStrokeColor(UIColor.systemGray.cgColor)
        cg.setLineWidth(1)
        cg.beginPath()
        cg.move(to: CGPoint(x: plot.minX, y: zeroY))
        cg.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
        cg.strokePath()
        cg.setStrokeColor(UIColor.systemPurple.cgColor)
        cg.setLineWidth(3)
        cg.beginPath()
        for i in 0..<n {
            let x = plot.minX + CGFloat(i) / CGFloat(n - 1) * plot.width
            let y = zeroY - CGFloat(pitch[i] / absMax) * (plot.height / 2)
            if i == 0 { cg.move(to: CGPoint(x: x, y: y)) }
            else      { cg.addLine(to: CGPoint(x: x, y: y)) }
        }
        cg.strokePath()
    }

    private static func drawHeightSeries(_ cg: CGContext, plot: CGRect, baro: [Double], fused: [Double]) {
        let n = fused.count
        guard n >= 2 else { return }
        var minV = Double.infinity
        var maxV = -Double.infinity
        for v in baro { if v < minV { minV = v }; if v > maxV { maxV = v } }
        for v in fused { if v < minV { minV = v }; if v > maxV { maxV = v } }
        if maxV - minV < 0.2 { minV -= 0.1; maxV += 0.1 }
        let span = maxV - minV
        func draw(_ arr: [Double], color: UIColor, width: CGFloat) {
            guard arr.count >= 2 else { return }
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(width)
            cg.beginPath()
            for i in 0..<arr.count {
                let x = plot.minX + CGFloat(i) / CGFloat(arr.count - 1) * plot.width
                let y = plot.maxY - CGFloat((arr[i] - minV) / span) * plot.height
                if i == 0 { cg.move(to: CGPoint(x: x, y: y)) }
                else      { cg.addLine(to: CGPoint(x: x, y: y)) }
            }
            cg.strokePath()
        }
        draw(baro, color: UIColor.systemGray, width: 1.5)
        draw(fused, color: UIColor.systemBlue, width: 3)
    }

    private static func drawGpsTrack(_ cg: CGContext, plot: CGRect, rows: [GpsRow]) {
        guard rows.count >= 2 else { return }
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for r in rows {
            if r.lat < minLat { minLat = r.lat }
            if r.lat > maxLat { maxLat = r.lat }
            if r.lon < minLon { minLon = r.lon }
            if r.lon > maxLon { maxLon = r.lon }
        }
        let meanLat = (minLat + maxLat) / 2.0
        let lonScale = cos(meanLat * .pi / 180.0)
        let latSpan = max(maxLat - minLat, 1e-9)
        let lonSpan = max((maxLon - minLon) * lonScale, 1e-9)
        let scale = min(plot.width / lonSpan, plot.height / latSpan)
        let lonMid = (minLon + maxLon) / 2.0
        let latMid = (minLat + maxLat) / 2.0
        func project(_ lat: Double, _ lon: Double) -> CGPoint {
            let dx = (lon - lonMid) * lonScale * scale
            let dy = (lat - latMid) * scale
            return CGPoint(x: plot.midX + CGFloat(dx), y: plot.midY - CGFloat(dy))
        }
        cg.setStrokeColor(UIColor.systemTeal.cgColor)
        cg.setLineWidth(3)
        cg.beginPath()
        for i in 0..<rows.count {
            let p = project(rows[i].lat, rows[i].lon)
            if i == 0 { cg.move(to: p) } else { cg.addLine(to: p) }
        }
        cg.strokePath()
    }

    // -------------------------------------------------------------------------
    //  Cursor animations
    // -------------------------------------------------------------------------

    /// Per-step (X-translation) keyframes for cursor lines on panels 0..2.
    /// Plot inset is applied so the cursor stays inside the data area.
    private static func sweepCursorValues(
        panelIndex: Int, durationS: Double, panelWidth: CGFloat,
        inputs: CompositeExportInputs
    ) -> (values: [CGFloat], keyTimes: [Double]) {
        let inset = UIEdgeInsets(top: 56, left: 16, bottom: 16, right: 16)
        let plotMinX = inset.left
        let plotW = panelWidth - inset.left - inset.right

        let stepS = 1.0 / 30.0
        let steps = max(2, Int((durationS / stepS).rounded()))

        let times: [Int64]
        let count: Int
        switch panelIndex {
        case 0:
            times = inputs.gpsAbsTimesMs
            count = inputs.speedSmoothedKmh.count
        case 1:
            times = inputs.sensorAbsTimesMs
            count = inputs.pitchDeg.count
        default:
            times = inputs.sensorAbsTimesMs
            count = inputs.fusedHeightM.count
        }
        let videoCreation = inputs.videoCreationMs

        var values: [CGFloat] = []
        var keyTimes: [Double] = []
        for s in 0..<steps {
            let t = Double(s) / Double(steps - 1)
            let videoTimeMs = Int64(t * durationS * 1000.0)
            let target = videoCreation + videoTimeMs
            let idx = nearestIndexByTime(times, target: target)
            let xRel: CGFloat
            if count >= 2, idx >= 0 {
                xRel = plotMinX + CGFloat(idx) / CGFloat(count - 1) * plotW
            } else {
                xRel = plotMinX
            }
            values.append(xRel)
            keyTimes.append(t)
        }
        return (values, keyTimes)
    }

    /// (x, y) keyframes for the GPS track dot.
    private static func gpsDotValues(
        durationS: Double, panelSize: CGSize, inputs: CompositeExportInputs
    ) -> (x: [CGFloat], y: [CGFloat], keyTimes: [Double]) {
        let inset = UIEdgeInsets(top: 56, left: 16, bottom: 16, right: 16)
        let plot = CGRect(
            x: inset.left, y: inset.top,
            width: panelSize.width - inset.left - inset.right,
            height: panelSize.height - inset.top - inset.bottom
        )

        let stepS = 1.0 / 30.0
        let steps = max(2, Int((durationS / stepS).rounded()))

        guard inputs.gpsRows.count >= 2 else {
            return (
                Array(repeating: plot.midX, count: steps),
                Array(repeating: plot.midY, count: steps),
                (0..<steps).map { Double($0) / Double(max(steps - 1, 1)) }
            )
        }
        var minLat = Double.infinity, maxLat = -Double.infinity
        var minLon = Double.infinity, maxLon = -Double.infinity
        for r in inputs.gpsRows {
            if r.lat < minLat { minLat = r.lat }
            if r.lat > maxLat { maxLat = r.lat }
            if r.lon < minLon { minLon = r.lon }
            if r.lon > maxLon { maxLon = r.lon }
        }
        let meanLat = (minLat + maxLat) / 2.0
        let lonScale = cos(meanLat * .pi / 180.0)
        let latSpan = max(maxLat - minLat, 1e-9)
        let lonSpan = max((maxLon - minLon) * lonScale, 1e-9)
        let scale = min(plot.width / lonSpan, plot.height / latSpan)
        let lonMid = (minLon + maxLon) / 2.0
        let latMid = (minLat + maxLat) / 2.0
        let videoCreation = inputs.videoCreationMs

        var xs: [CGFloat] = []
        var ys: [CGFloat] = []
        var keys: [Double] = []
        for s in 0..<steps {
            let t = Double(s) / Double(steps - 1)
            let videoTimeMs = Int64(t * durationS * 1000.0)
            let target = videoCreation + videoTimeMs
            let idx = nearestIndexByTime(inputs.gpsAbsTimesMs, target: target)
            let row = (idx >= 0 && idx < inputs.gpsRows.count)
                ? inputs.gpsRows[idx] : inputs.gpsRows[0]
            let dx = (row.lon - lonMid) * lonScale * scale
            let dy = (row.lat - latMid) * scale
            xs.append(plot.midX + CGFloat(dx))
            ys.append(plot.midY - CGFloat(dy))
            keys.append(t)
        }
        return (xs, ys, keys)
    }

    private static func nearestIndexByTime(_ arr: [Int64], target: Int64) -> Int {
        let n = arr.count
        guard n > 0 else { return -1 }
        var lo = 0
        while lo < n && arr[lo] < 0 { lo += 1 }
        if lo >= n { return -1 }
        var hi = n - 1
        if target <= arr[lo] { return lo }
        if target >= arr[hi] { return hi }
        while lo < hi {
            let mid = (lo + hi) >> 1
            if arr[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
