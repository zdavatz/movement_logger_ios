import Foundation
import AVFoundation
import UIKit

/// Merge N clips (chronological order) into one film:
///
///   [title card 2.5 s] [clip 1, complete, 3 s fade-out]
///   [title card 2.5 s] [clip 2, complete, 3 s fade-out] …
///   [Pump Tsüri logo outro 5 s]
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
    /// Pump Tsüri logo outro closing the film — ONCE, after the last
    /// clip's fade-out (not per clip). Black background, RideLogo centered.
    private static let outroS: Double = 5.0
    /// Logo height as a fraction of the render height.
    private static let outroLogoHeightFrac: CGFloat = 0.45

    static func export(
        clips: [MergeClipSpec],
        panelKinds: [CompositeExporter.PanelKind],
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard !clips.isEmpty else { throw MergeExportError.noClips }
        progress(0.001)

        // Diagnostic knobs (env MERGE_DEBUG, comma-separated:
        // noaudio,noca,nogaps,nooutro,novc,nosdr) — used by the headless
        // `MERGE_SELFTEST` harness to bisect export failures by layer.
        // Notably `noca` (skip the CoreAnimation overlay tool) is what makes
        // the merge verifiable on a SIMULATOR at all: the sim's offline CA
        // render (GLES + IOSurface xpc shmem) crashes on real layer trees —
        // a long-standing simulator limitation; overlays need a device.
        // Always empty in production (no env vars in a normal app launch).
        let dbg = Set((ProcessInfo.processInfo.environment["MERGE_DEBUG"] ?? "")
            .split(separator: ",").map(String.init))
        let titleS = dbg.contains("nogaps") ? 0.0 : titleCardS
        let outroSecs = (dbg.contains("nogaps") || dbg.contains("nooutro")) ? 0.0 : outroS

        // ----- Load per-clip assets + geometry
        struct Loaded {
            let spec: MergeClipSpec
            /// The source asset MUST be retained here for the whole export:
            /// `AVAssetTrack.asset` is a WEAK reference, so keeping only the
            /// tracks deallocates each AVURLAsset at the end of its loop
            /// iteration — the composition then can't read any source media
            /// and AVAssetExportSession fails instantly with -11800 /
            /// OSStatus -12780 ("The operation could not be completed").
            /// This was the real-device 14-clip merge failure.
            let asset: AVURLAsset
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
                spec: spec, asset: asset,
                videoTrack: vTrack, audioTrack: aTrack, audioRange: aRange,
                duration: duration, naturalSize: natural, preferredTransform: xform,
                displayedW: abs(displayed.width).rounded(),
                displayedH: abs(displayed.height).rounded()
            ))
        }
        // Guarantee the source assets outlive the export even under
        // aggressive ARC (`loaded`'s last plain use is before the await).
        defer { withExtendedLifetime(loaded) {} }

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
        // Created lazily on the first clip that actually has audio — a
        // composition track with zero segments (all clips muted) is a
        // known export-breaker.
        var compAudio: AVMutableCompositionTrack? = nil

        struct Segment {
            let loaded: Loaded
            let titleStart: CMTime
            let clipStart: CMTime
            let clipEnd: CMTime
        }
        let titleDur = CMTime(value: Int64(titleS * 1000), timescale: 1000)
        var cursor = CMTime.zero
        var audioCursor = CMTime.zero
        var segments: [Segment] = []
        for l in loaded {
            let titleStart = cursor
            let clipStart = CMTimeAdd(titleStart, titleDur)
            if titleS > 0 {
                compVideo.insertEmptyTimeRange(CMTimeRange(start: titleStart, duration: titleDur))
            }
            try compVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: l.duration),
                of: l.videoTrack, at: clipStart
            )
            let clipEnd = CMTimeAdd(clipStart, l.duration)
            // Audio passthrough at the clip's offset; title gaps stay silent.
            // Clamp to the audio track's own extent (it can trail the video
            // by a frame or two) and never let an audio hiccup kill the merge.
            if !dbg.contains("noaudio"), let a = l.audioTrack {
                if compAudio == nil {
                    compAudio = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let audioTrack = compAudio {
                    if CMTimeCompare(audioCursor, clipStart) < 0 {
                        audioTrack.insertEmptyTimeRange(
                            CMTimeRange(start: audioCursor, end: clipStart))
                    }
                    let aDur = CMTimeMinimum(l.audioRange.duration, l.duration)
                    try? audioTrack.insertTimeRange(
                        CMTimeRange(start: l.audioRange.start, duration: aDur),
                        of: a, at: clipStart
                    )
                    audioCursor = CMTimeAdd(clipStart, aDur)
                }
            }
            segments.append(Segment(
                loaded: l, titleStart: titleStart, clipStart: clipStart, clipEnd: clipEnd))
            cursor = clipEnd
        }

        // ----- 5 s logo outro after the last clip's fade-out. A trailing
        // EMPTY edit does not work here — AVFoundation silently drops empty
        // edits at the end of a composition track, so the film would just
        // end at the last clip (verified: 95.1 s instead of 100.1 s).
        // Freezing a frame of the last clip across the outro was tried and
        // is codec-dependent (a scaled 10-bit HEVC sample silently
        // truncated the export at the last clip). The timeline is instead
        // anchored with a tiny SYNTHESIZED black clip (AVAssetWriter,
        // 64×64 H.264) — never rendered: the outro instruction has no
        // layer instruction for the track, so the output is the black
        // background + logo layer. No clip content is touched.
        let outroStart = cursor
        var outroAnchor: AVURLAsset? = nil
        defer { withExtendedLifetime(outroAnchor) {} }
        if outroSecs > 0 {
            do {
                let anchor = try await makeBlackAnchorAsset(durationS: outroSecs)
                guard let anchorTrack = try await anchor.loadTracks(withMediaType: .video).first
                else { throw MergeExportError.exportFailed("anchor clip has no video track") }
                let outroDur = CMTime(value: Int64(outroSecs * 1000), timescale: 1000)
                try compVideo.insertTimeRange(
                    CMTimeRange(start: .zero, duration: outroDur),
                    of: anchorTrack, at: outroStart
                )
                outroAnchor = anchor   // keep alive through the export
                cursor = CMTimeAdd(outroStart, outroDur)
            } catch {
                // No anchor — the film simply ends after the last clip.
            }
        }

        let totalDur = cursor
        let totalS = CMTimeGetSeconds(totalDur)

        progress(0.01)

        // ----- Video composition instructions: [title gap][clip] per clip,
        // tiling [0, totalDur] exactly (shared CMTime boundaries).
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for seg in segments {
            if titleS > 0 {
                let gap = AVMutableVideoCompositionInstruction()
                gap.timeRange = CMTimeRange(start: seg.titleStart, end: seg.clipStart)
                gap.backgroundColor = UIColor.black.cgColor
                gap.layerInstructions = []   // just the black background
                instructions.append(gap)
            }

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

        // Outro instruction: plain black background (the frozen anchor frame
        // is deliberately NOT given a layer instruction, so it never renders)
        // — the logo itself is a CALayer opacity-gated to this segment.
        if outroSecs > 0, CMTimeCompare(totalDur, outroStart) > 0 {
            let outroInst = AVMutableVideoCompositionInstruction()
            outroInst.timeRange = CMTimeRange(start: outroStart, end: totalDur)
            outroInst.backgroundColor = UIColor.black.cgColor
            outroInst.layerInstructions = []
            instructions.append(outroInst)
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
            // The layer is a TIGHT text strip, not a full-canvas image —
            // N full-canvas RGBA layers ballooned the offline renderer's
            // IOSurface usage (a 14-clip merge crashed the simulator's CA
            // render in xpc_shmem_create) and waste memory on device too.
            if titleS > 0, let title = makeTitleLayer(
                startEpochMs: seg.loaded.spec.startEpochMs, canvasSize: outputSize
            ) {
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

        // Logo outro layer: RideLogo centered on black at ~45% of the render
        // height, visible only during the trailing outro segment.
        if outroSecs > 0, let logo = UIImage(named: "RideLogo")?.cgImage {
            let imgW = CGFloat(logo.width)
            let imgH = CGFloat(logo.height)
            var h = outputSize.height * outroLogoHeightFrac
            var w = imgH > 0 ? h * (imgW / imgH) : h
            if w > outputSize.width * 0.8 {
                let shrink = outputSize.width * 0.8 / w
                w *= shrink
                h *= shrink
            }
            let logoLayer = CALayer()
            logoLayer.contents = logo
            logoLayer.contentsGravity = .resize
            logoLayer.frame = CGRect(
                x: (outputSize.width - w) / 2,
                y: (outputSize.height - h) / 2,
                width: w, height: h
            )
            gateOpacity(
                logoLayer,
                fromS: CMTimeGetSeconds(outroStart), toS: totalS, totalS: totalS
            )
            parentLayer.addSublayer(logoLayer)
        }

        // ----- Video composition + export
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = outputSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        // Force an SDR (Rec.709) rendering path. iPhone camera clips are
        // 10-bit HDR (Dolby Vision / HLG, BT.2020); letting the composition
        // infer HDR color properties while a CoreAnimation overlay tool is
        // attached makes AVAssetExportSession fail (-11800 / OSStatus
        // -12780). Rec.709 output also keeps a mixed SDR+HDR clip list
        // uniform in the merged film.
        if !dbg.contains("nosdr") {
            videoComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            videoComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        }
        if !dbg.contains("noca") {
            videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer
            )
        }
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
        if !dbg.contains("novc") {
            session.videoComposition = videoComp
        }
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
            // Surface the FULL failure identity — AVFoundation's
            // localizedDescription alone ("The operation could not be
            // completed") is undiagnosable from a user bug report. Append
            // the NSError domain+code+underlying chain, plus the video
            // composition's own validation findings when it is the culprit.
            var detail = describeError(session.error)
            let findings = validationFindings(videoComp, for: composition)
            if !findings.isEmpty {
                detail += " · composition invalid: " + findings.joined(separator: "; ")
            }
            throw MergeExportError.exportFailed(detail)
        case .cancelled:
            throw MergeExportError.exportFailed("cancelled")
        default:
            throw MergeExportError.exportFailed("status \(session.status.rawValue)")
        }
    }

    private static func describeError(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        let ns = error as NSError
        var msg = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if let reason = ns.localizedFailureReason { msg += " — \(reason)" }
        var underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        while let u = underlying {
            msg += " ← \(u.domain) \(u.code): \(u.localizedDescription)"
            underlying = u.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return msg
    }

    /// Run AVFoundation's own composition validation and report what it
    /// flags (bad instruction time ranges, gaps, bad track ids). Only
    /// called on the failure path — costs nothing on success.
    private static func validationFindings(
        _ videoComp: AVVideoComposition, for composition: AVComposition
    ) -> [String] {
        final class Log: NSObject, AVVideoCompositionValidationHandling {
            var findings: [String] = []
            fileprivate func fmt(_ r: CMTimeRange) -> String {
                String(format: "[%.4f..%.4f]",
                       CMTimeGetSeconds(r.start), CMTimeGetSeconds(CMTimeRangeGetEnd(r)))
            }
            func videoComposition(
                _ vc: AVVideoComposition,
                shouldContinueValidatingAfterFindingInvalidValueForKey key: String
            ) -> Bool { findings.append("invalid value for \(key)"); return true }
            func videoComposition(
                _ vc: AVVideoComposition,
                shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange
            ) -> Bool { findings.append("uncovered time range \(fmt(timeRange))"); return true }
            func videoComposition(
                _ vc: AVVideoComposition,
                shouldContinueValidatingAfterFindingInvalidTimeRangeIn
                    videoCompositionInstruction: AVVideoCompositionInstructionProtocol
            ) -> Bool {
                findings.append("bad instruction range \(fmt(videoCompositionInstruction.timeRange))")
                return true
            }
            func videoComposition(
                _ vc: AVVideoComposition,
                shouldContinueValidatingAfterFindingInvalidTrackID trackID: CMPersistentTrackID,
                asset: AVAsset, layerInstruction: AVVideoCompositionLayerInstruction
            ) -> Bool { findings.append("bad track id \(trackID)"); return true }
        }
        let log = Log()
        _ = videoComp.isValid(
            for: composition,
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            validationDelegate: log
        )
        return log.findings
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

    /// Write a tiny black H.264 clip of `durationS` seconds (64×64, two
    /// frames) into tmp and return it as an asset. Used only to anchor the
    /// outro segment of the composition timeline — its pixels are never
    /// rendered, so size and codec are irrelevant; what matters is that
    /// every AVFoundation reader handles it.
    private static func makeBlackAnchorAsset(durationS: Double) async throws -> AVURLAsset {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge_outro_anchor.mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw MergeExportError.exportFailed(
                "anchor writer: \(writer.error?.localizedDescription ?? "startWriting failed")")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw MergeExportError.exportFailed("anchor writer: no pixel buffer pool")
        }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else {
            throw MergeExportError.exportFailed("anchor writer: no pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetDataSize(pb))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        // Two frames: one at 0 and one near the end, so the track's media
        // extent genuinely spans the outro duration.
        let times = [
            CMTime.zero,
            CMTime(seconds: max(durationS - 1.0 / 30.0, 1.0 / 30.0), preferredTimescale: 600),
        ]
        for t in times {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(10))
            }
            adaptor.append(pb, withPresentationTime: t)
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: durationS, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MergeExportError.exportFailed(
                "anchor writer: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
        }
        return AVURLAsset(url: url)
    }

    /// Title card layer: recording date (dd.MM.yyyy) above start time
    /// (HH:mm:ss), local timezone, white, centered on the (black) canvas.
    /// The backing image is only as tall as the two text lines — the layer
    /// is positioned so its content lands dead-center of the canvas.
    private static func makeTitleLayer(
        startEpochMs: Int64, canvasSize: CGSize
    ) -> CALayer? {
        let date = Date(timeIntervalSince1970: TimeInterval(startEpochMs) / 1000.0)
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "dd.MM.yyyy"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH:mm:ss"
        let dateText = df.string(from: date)   // local timezone (default)
        let timeText = tf.string(from: date)

        let dateFont = UIFont.systemFont(
            ofSize: max(28, canvasSize.width * 0.055), weight: .semibold)
        let timeFont = UIFont.monospacedDigitSystemFont(
            ofSize: max(36, canvasSize.width * 0.08), weight: .bold)
        let dateAttrs: [NSAttributedString.Key: Any] = [
            .font: dateFont, .foregroundColor: UIColor.white,
        ]
        let timeAttrs: [NSAttributedString.Key: Any] = [
            .font: timeFont, .foregroundColor: UIColor.white,
        ]
        let dateSize = (dateText as NSString).size(withAttributes: dateAttrs)
        let timeSize = (timeText as NSString).size(withAttributes: timeAttrs)
        let gap: CGFloat = canvasSize.width * 0.02
        let pad: CGFloat = 8
        let stripSize = CGSize(
            width: canvasSize.width,
            height: (dateSize.height + gap + timeSize.height + 2 * pad).rounded(.up)
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // export-only render — avoid the device-scale trap
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: stripSize, format: format)
        let img = renderer.image { _ in
            (dateText as NSString).draw(
                at: CGPoint(x: (stripSize.width - dateSize.width) / 2, y: pad),
                withAttributes: dateAttrs
            )
            (timeText as NSString).draw(
                at: CGPoint(
                    x: (stripSize.width - timeSize.width) / 2,
                    y: pad + dateSize.height + gap
                ),
                withAttributes: timeAttrs
            )
        }
        guard let cg = img.cgImage else { return nil }
        let layer = CALayer()
        layer.contents = cg
        layer.contentsGravity = .resize
        layer.isGeometryFlipped = true   // keep top-down text layout
        layer.frame = CGRect(
            x: 0,
            y: (canvasSize.height - stripSize.height) / 2,
            width: stripSize.width,
            height: stripSize.height
        )
        return layer
    }
}
