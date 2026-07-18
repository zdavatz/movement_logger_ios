import Foundation
import AVFoundation
import UIKit

/// Merge N clips (chronological order) into one film:
///
///   [title card 2.5 s] [clip 1, complete, 3 s fade-out]
///   [title card 2.5 s] [clip 2, complete, 3 s fade-out] …
///
/// Each title card is black with the clip's recording date (dd.MM.yyyy)
/// above its start time (HH:mm:ss), local timezone, white text. Clips are
/// inserted with their FULL time range — never trimmed ("never cut a
/// video!" is a hard product rule); the fade is an opacity ramp to black
/// over the clip's last 3 s, so every frame still ships.
///
/// When `panelKinds` is non-empty each clip also carries the Replay-style
/// sensor-panel stack below the video (same painters + cursor sweeps as
/// `CompositeExporter`, reused via its internal helpers), fed by that
/// clip's slice of the session CSVs. With `panelKinds` empty the merge is
/// plain video only.
///
/// Same pipeline as the single-clip export: `AVMutableComposition` +
/// `AVMutableVideoComposition` (one instruction per title gap / clip
/// segment) + `AVVideoCompositionCoreAnimationTool`, exported through
/// `AVAssetExportSession` at highest quality. Per-clip overlays (title
/// cards, panel stacks) are CALayers opacity-gated to their segment via
/// discrete keyframe animations on the film timeline; cursor / live-value
/// animations get `beginTime = AVCoreAnimationBeginTimeAtZero + segment
/// start` so they run in lock-step with their clip.
struct MergeClipSpec {
    let url: URL
    /// Wall-clock start of the recording (creation_time, or file-date
    /// fallback) — drives the title-card text and the panel alignment.
    let startEpochMs: Int64
    /// This clip's slice of the session data; nil when merging plain.
    let panelInputs: CompositeExportInputs?
}

enum MergeExportError: Error, LocalizedError {
    case noClips
    case noVideoTrack(String)
    case exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .noClips:             return "no clips to merge"
        case .noVideoTrack(let n): return "\(n) has no video track"
        case .exportFailed(let m): return "merge export failed: \(m)"
        }
    }
}

enum MergeExporter {

    /// Black title card shown before every clip.
    private static let titleCardS: Double = 2.5
    /// Fade-to-black over the clip's last seconds (clamped to clip length).
    private static let fadeOutS: Double = 3.0

    static func export(
        clips: [MergeClipSpec],
        panelKinds: [CompositeExporter.PanelKind],
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard !clips.isEmpty else { throw MergeExportError.noClips }
        progress(0.001)

        // ----- Load per-clip assets + geometry
        struct Loaded {
            let spec: MergeClipSpec
            let videoTrack: AVAssetTrack
            let audioTrack: AVAssetTrack?
            let audioRange: CMTimeRange
            let duration: CMTime
            let naturalSize: CGSize
            let preferredTransform: CGAffineTransform
            let displayedW: CGFloat
            let displayedH: CGFloat
        }
        var loaded: [Loaded] = []
        for spec in clips {
            let asset = AVURLAsset(url: spec.url)
            guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw MergeExportError.noVideoTrack(spec.url.lastPathComponent)
            }
            let aTrack: AVAssetTrack? = try? await asset.loadTracks(withMediaType: .audio).first
            var aRange = CMTimeRange.zero
            if let a = aTrack, let r = try? await a.load(.timeRange) { aRange = r }
            let duration = try await asset.load(.duration)
            let natural = try await vTrack.load(.naturalSize)
            let xform = try await vTrack.load(.preferredTransform)
            let displayed = CGRect(origin: .zero, size: natural).applying(xform)
            loaded.append(Loaded(
                spec: spec, videoTrack: vTrack, audioTrack: aTrack, audioRange: aRange,
                duration: duration, naturalSize: natural, preferredTransform: xform,
                displayedW: abs(displayed.width).rounded(),
                displayedH: abs(displayed.height).rounded()
            ))
        }

        // ----- Common render geometry: aspect-fit every clip into the
        // largest displayed frame (even dimensions for the H.264 encoder).
        func evenDown(_ v: CGFloat) -> CGFloat {
            let r = max(v.rounded(), 2)
            return r - r.truncatingRemainder(dividingBy: 2)
        }
        let videoW = evenDown(loaded.map { $0.displayedW }.max() ?? 1080)
        let videoH = evenDown(loaded.map { $0.displayedH }.max() ?? 1920)
        let panelStackH = CompositeExporter.panelHeight * CGFloat(panelKinds.count)
        let outputSize = CGSize(width: videoW, height: videoH + panelStackH)
        let panelSize = CGSize(width: videoW, height: CompositeExporter.panelHeight)

        // ----- Composition. One video + one audio track; an explicit empty
        // (black) 2.5 s edit before every clip carries its title card. Each
        // clip is inserted with its FULL [0, duration] range — never a
        // sub-range (hard product rule: no trimming).
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw MergeExportError.exportFailed("could not add video track") }
        let compAudio = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        struct Segment {
            let loaded: Loaded
            let titleStart: CMTime
            let clipStart: CMTime
            let clipEnd: CMTime
        }
        let titleDur = CMTime(value: Int64(titleCardS * 1000), timescale: 1000)
        var cursor = CMTime.zero
        var audioCursor = CMTime.zero
        var segments: [Segment] = []
        for l in loaded {
            let titleStart = cursor
            let clipStart = CMTimeAdd(titleStart, titleDur)
            compVideo.insertEmptyTimeRange(CMTimeRange(start: titleStart, duration: titleDur))
            try compVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: l.duration),
                of: l.videoTrack, at: clipStart
            )
            let clipEnd = CMTimeAdd(clipStart, l.duration)
            // Audio passthrough at the clip's offset; title gaps stay silent.
            // Clamp to the audio track's own extent (it can trail the video
            // by a frame or two) and never let an audio hiccup kill the merge.
            if let a = l.audioTrack, let compAudio {
                if CMTimeCompare(audioCursor, clipStart) < 0 {
                    compAudio.insertEmptyTimeRange(
                        CMTimeRange(start: audioCursor, end: clipStart))
                }
                let aDur = CMTimeMinimum(l.audioRange.duration, l.duration)
                try? compAudio.insertTimeRange(
                    CMTimeRange(start: l.audioRange.start, duration: aDur),
                    of: a, at: clipStart
                )
                audioCursor = CMTimeAdd(clipStart, aDur)
            }
            segments.append(Segment(
                loaded: l, titleStart: titleStart, clipStart: clipStart, clipEnd: clipEnd))
            cursor = clipEnd
        }
        let totalDur = cursor
        let totalS = CMTimeGetSeconds(totalDur)

        progress(0.01)

        // ----- Video composition instructions: [title gap][clip] per clip,
        // tiling [0, totalDur] exactly (shared CMTime boundaries).
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for seg in segments {
            let gap = AVMutableVideoCompositionInstruction()
            gap.timeRange = CMTimeRange(start: seg.titleStart, end: seg.clipStart)
            gap.backgroundColor = UIColor.black.cgColor
            gap.layerInstructions = []   // just the black background
            instructions.append(gap)

            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = CMTimeRange(start: seg.clipStart, end: seg.clipEnd)
            inst.backgroundColor = UIColor.black.cgColor
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)

            // Orient the source into the origin quadrant (same normalization
            // as CompositeExporter), then aspect-fit + center it into the
            // common video region at the TOP of the render canvas.
            let l = seg.loaded
            var xform = l.preferredTransform
            let rotated = CGRect(origin: .zero, size: l.naturalSize)
                .applying(l.preferredTransform)
            xform = xform.concatenating(CGAffineTransform(
                translationX: -rotated.origin.x, y: -rotated.origin.y))
            let w = abs(rotated.width)
            let h = abs(rotated.height)
            if w > 0, h > 0 {
                let s = min(videoW / w, videoH / h)
                xform = xform.concatenating(CGAffineTransform(scaleX: s, y: s))
                xform = xform.concatenating(CGAffineTransform(
                    translationX: (videoW - w * s) / 2, y: (videoH - h * s) / 2))
            }
            li.setTransform(xform, at: seg.clipStart)
            li.setOpacity(1.0, at: seg.clipStart)

            // 3 s fade-out: opacity ramp to 0 over the clip's last seconds —
            // the render background is black, so 0 opacity == faded to black.
            // The clip itself stays complete; nothing is cut.
            let clipS = CMTimeGetSeconds(l.duration)
            let fadeS = min(fadeOutS, clipS)
            if fadeS > 0.05 {
                let fadeStart = CMTimeSubtract(
                    seg.clipEnd, CMTime(seconds: fadeS, preferredTimescale: 600))
                li.setOpacityRamp(
                    fromStartOpacity: 1.0, toEndOpacity: 0.0,
                    timeRange: CMTimeRange(start: fadeStart, end: seg.clipEnd))
            }
            inst.layerInstructions = [li]
            instructions.append(inst)
        }

        // ----- CALayer tree: per-clip title cards + panel stacks, each
        // opacity-gated to its segment of the film timeline.
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        parentLayer.backgroundColor = UIColor.black.cgColor
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame   // FULL parent — no inner letterbox
        parentLayer.addSublayer(videoLayer)

        for seg in segments {
            let titleStartS = CMTimeGetSeconds(seg.titleStart)
            let clipStartS = CMTimeGetSeconds(seg.clipStart)
            let clipEndS = CMTimeGetSeconds(seg.clipEnd)
            let clipDurS = max(clipEndS - clipStartS, 0.001)

            // Title card: white date over start time, centered on black.
            if let img = renderTitleImage(
                startEpochMs: seg.loaded.spec.startEpochMs, size: outputSize
            ) {
                let title = CALayer()
                title.frame = parentLayer.frame
                title.isGeometryFlipped = true   // keep top-down text layout
                title.contents = img
                title.contentsGravity = .resize
                gateOpacity(title, fromS: titleStartS, toS: clipStartS, totalS: totalS)
                parentLayer.addSublayer(title)
            }

            // Panel stack for this clip (only when sensor data was selected).
            guard !panelKinds.isEmpty, let inputs = seg.loaded.spec.panelInputs else {
                continue
            }
            let container = CALayer()
            container.frame = parentLayer.frame
            gateOpacity(container, fromS: clipStartS, toS: clipEndS, totalS: totalS)
            for (slot, kind) in panelKinds.enumerated() {
                let panel = CALayer()
                // Y-up Quartz: slot 0 sits at the HIGH-Y side of the panel
                // area — directly below the video (same as CompositeExporter).
                let yQuartz = CGFloat(panelKinds.count - 1 - slot)
                    * CompositeExporter.panelHeight
                panel.frame = CGRect(
                    origin: CGPoint(x: 0, y: yQuartz), size: panelSize)
                panel.isGeometryFlipped = true
                panel.contents = CompositeExporter.renderPanelImage(
                    index: kind.rawValue, size: panelSize, inputs: inputs)
                panel.contentsGravity = .resize

                // Cursor sweep / GPS dot + live labels only when this clip's
                // slice actually has the series (a clip outside the session
                // window shows the empty panel frame — no crash, no cursor).
                if kindHasData(kind, inputs) {
                    if kind != .gpsTrack {
                        let cursorLayer = CAShapeLayer()
                        cursorLayer.frame = CGRect(origin: .zero, size: panelSize)
                        cursorLayer.lineWidth = 4
                        cursorLayer.strokeColor = UIColor.systemRed.cgColor
                        let path = CGMutablePath()
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: panelSize.height))
                        cursorLayer.path = path
                        let (values, keyTimes) = CompositeExporter.sweepCursorValues(
                            panelIndex: kind.rawValue, durationS: clipDurS,
                            panelWidth: videoW, inputs: inputs
                        )
                        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
                        anim.values = values
                        anim.keyTimes = keyTimes.map { NSNumber(value: $0) }
                        anim.duration = clipDurS
                        anim.beginTime = AVCoreAnimationBeginTimeAtZero + clipStartS
                        anim.fillMode = .both
                        anim.isRemovedOnCompletion = false
                        cursorLayer.add(anim, forKey: "sweep")
                        panel.addSublayer(cursorLayer)
                    } else {
                        let dotR: CGFloat = 14
                        let dot = CAShapeLayer()
                        dot.frame = CGRect(
                            x: -dotR, y: -dotR, width: dotR * 2, height: dotR * 2)
                        dot.path = CGPath(
                            ellipseIn: CGRect(x: 0, y: 0, width: dotR * 2, height: dotR * 2),
                            transform: nil
                        )
                        dot.fillColor = UIColor.systemRed.cgColor
                        let (xs, ys, keyTimes) = CompositeExporter.gpsDotValues(
                            durationS: clipDurS, panelSize: panelSize, inputs: inputs
                        )
                        let anim = CAKeyframeAnimation(keyPath: "position")
                        anim.values = zip(xs, ys).map { x, y in
                            NSValue(cgPoint: CGPoint(x: x, y: y))
                        }
                        anim.keyTimes = keyTimes.map { NSNumber(value: $0) }
                        anim.duration = clipDurS
                        anim.beginTime = AVCoreAnimationBeginTimeAtZero + clipStartS
                        anim.fillMode = .both
                        anim.isRemovedOnCompletion = false
                        dot.add(anim, forKey: "gps-dot")
                        panel.addSublayer(dot)
                    }
                    if let live = CompositeExporter.makeLiveValueLayer(
                        panelIndex: kind.rawValue, panelSize: panelSize,
                        durationS: clipDurS, inputs: inputs,
                        beginOffsetS: clipStartS
                    ) {
                        panel.addSublayer(live)
                    }
                }
                container.addSublayer(panel)
            }
            parentLayer.addSublayer(container)
        }

        // ----- Video composition + export
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = outputSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parentLayer
        )
        videoComp.instructions = instructions

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw MergeExportError.exportFailed("could not create export session")
        }
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComp
        session.shouldOptimizeForNetworkUse = true

        progress(0.03)
        let poller = CompositeExporter.ProgressPoller(session: session) { p in
            progress(0.03 + 0.97 * max(0, min(p, 1)))
        }
        poller.start()
        await session.export()
        poller.stop()

        switch session.status {
        case .completed:
            progress(1.0)
        case .failed:
            throw MergeExportError.exportFailed(
                session.error?.localizedDescription ?? "unknown")
        case .cancelled:
            throw MergeExportError.exportFailed("cancelled")
        default:
            throw MergeExportError.exportFailed("status \(session.status.rawValue)")
        }
    }

    // -------------------------------------------------------------------------
    //  Helpers
    // -------------------------------------------------------------------------

    /// Does this clip's slice carry enough data for `kind`'s cursor + live
    /// labels? (The static panel image is always rendered — its painters
    /// guard internally — but the animation builders index into the series
    /// and would trap on empty arrays.)
    private static func kindHasData(
        _ kind: CompositeExporter.PanelKind, _ inputs: CompositeExportInputs
    ) -> Bool {
        switch kind {
        case .speed:
            return inputs.speedSmoothedKmh.count >= 2 && !inputs.gpsAbsTimesMs.isEmpty
        case .pitch:
            return inputs.pitchDeg.count >= 2 && !inputs.sensorAbsTimesMs.isEmpty
        case .height:
            return inputs.fusedHeightM.count >= 2 && !inputs.baroHeightM.isEmpty
                && !inputs.sensorAbsTimesMs.isEmpty
        case .gpsTrack:
            return inputs.gpsRows.count >= 2 && !inputs.gpsAbsTimesMs.isEmpty
        }
    }

    /// Show `layer` only during [fromS, toS] of the film via a discrete
    /// opacity keyframe animation spanning the whole timeline. Discrete
    /// calculation mode wants keyTimes.count == values.count + 1.
    private static func gateOpacity(
        _ layer: CALayer, fromS: Double, toS: Double, totalS: Double
    ) {
        guard totalS > 0, toS > fromS else {
            layer.opacity = 0
            return
        }
        let f = max(0, min(fromS / totalS, 1))
        let t = max(f, min(toS / totalS, 1))
        var values: [Double] = []
        var keyTimes: [Double] = [0]
        if f > 0 { values.append(0); keyTimes.append(f) }
        values.append(1)
        if t < 1 { values.append(0); keyTimes.append(t) }
        keyTimes.append(1)
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = values
        anim.keyTimes = keyTimes.map { NSNumber(value: $0) }
        anim.calculationMode = .discrete
        anim.duration = totalS
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "gate")
    }

    /// Title card image: recording date (dd.MM.yyyy) above start time
    /// (HH:mm:ss), local timezone, white, centered. Transparent background —
    /// the render output behind it is already black during the gap.
    private static func renderTitleImage(
        startEpochMs: Int64, size: CGSize
    ) -> CGImage? {
        let date = Date(timeIntervalSince1970: TimeInterval(startEpochMs) / 1000.0)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "dd.MM.yyyy"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH:mm:ss"
        let dateText = df.string(from: date)   // local timezone (default)
        let timeText = tf.string(from: date)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // export-only render — avoid the device-scale trap
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let img = renderer.image { _ in
            let dateFont = UIFont.systemFont(
                ofSize: max(28, size.width * 0.055), weight: .semibold)
            let timeFont = UIFont.monospacedDigitSystemFont(
                ofSize: max(36, size.width * 0.08), weight: .bold)
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font: dateFont, .foregroundColor: UIColor.white,
            ]
            let timeAttrs: [NSAttributedString.Key: Any] = [
                .font: timeFont, .foregroundColor: UIColor.white,
            ]
            let dateSize = (dateText as NSString).size(withAttributes: dateAttrs)
            let timeSize = (timeText as NSString).size(withAttributes: timeAttrs)
            let gap: CGFloat = size.width * 0.02
            let totalH = dateSize.height + gap + timeSize.height
            let top = (size.height - totalH) / 2
            (dateText as NSString).draw(
                at: CGPoint(x: (size.width - dateSize.width) / 2, y: top),
                withAttributes: dateAttrs
            )
            (timeText as NSString).draw(
                at: CGPoint(
                    x: (size.width - timeSize.width) / 2,
                    y: top + dateSize.height + gap
                ),
                withAttributes: timeAttrs
            )
        }
        return img.cgImage
    }
}
