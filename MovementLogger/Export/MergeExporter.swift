import Foundation
import AVFoundation
import UIKit

/// Merge N clips (chronological order) into one film:
///
///   [MovementLogger intro card 3 s]
///   [title card 2.5 s] [clip 1, complete] [last-frame freeze fades out 3 s]
///   [title card 2.5 s] [clip 2, complete] [last-frame freeze fades out 3 s] …
///   [Pump Tsüri logo outro 5 s]
///
/// The intro card shows "MovementLogger" centered on black, each letter
/// colored along the logo gradient (orange → teal → blue → purple). Each
/// title card is black with the clip's recording date (dd.MM.yyyy) above
/// its start time (HH:mm:ss), local timezone, white text. Clips are
/// inserted with their FULL time range — never trimmed ("never cut a
/// video!" is a hard product rule) — and play COMPLETELY unfaded; the
/// fade-out happens AFTER the clip ends, on a 3 s freeze of its last
/// frame ("play every movie till the end and then add phase out over
/// 3 seconds"). The freeze is a rendered last-frame CALayer fading over
/// an empty (black) composition segment — deliberately NOT an
/// insert+scaleTimeRange of the source's tail: a scaled single-sample
/// segment from a 10-bit HEVC tail silently truncated the export (the
/// same codec quirk that forced the synthetic outro anchor).
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

    /// "MovementLogger" gradient intro card opening the film.
    private static let introCardS: Double = 3.0
    /// Black title card shown before every clip.
    private static let titleCardS: Double = 2.5
    /// Post-clip freeze: the clip's last frame held and faded to black.
    private static let fadeOutS: Double = 3.0
    /// Logo gradient stops for the intro lettering (orange → teal → blue
    /// → purple), interpolated linearly per letter.
    private static let introStops: [(r: CGFloat, g: CGFloat, b: CGFloat)] = [
        (247, 154, 51), (36, 195, 188), (62, 141, 243), (125, 77, 240),
    ]
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
        // noaudio,noca,nogaps,nooutro,novc,nosdr,nofreeze) — used by the
        // headless `MERGE_SELFTEST` harness to bisect export failures.
        // Notably `noca` (skip the CoreAnimation overlay tool) is what makes
        // the merge verifiable on a SIMULATOR at all: the sim's offline CA
        // render (GLES + IOSurface xpc shmem) crashes on real layer trees —
        // a long-standing simulator limitation; overlays need a device.
        // Always empty in production (no env vars in a normal app launch).
        let dbg = Set((ProcessInfo.processInfo.environment["MERGE_DEBUG"] ?? "")
            .split(separator: ",").map(String.init))
        let introS = dbg.contains("nogaps") ? 0.0 : introCardS
        let titleS = dbg.contains("nogaps") ? 0.0 : titleCardS
        let freezeS = dbg.contains("nogaps") ? 0.0 : fadeOutS
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
            /// End of the post-clip last-frame freeze (== clipEnd when the
            /// freeze is disabled by a diagnostic knob).
            let freezeEnd: CMTime
            /// Displayed size of the freeze segment's own video, when the
            /// freeze was inserted as real media (nil = no freeze media, the
            /// segment stays plain black).
            let freezeSize: CGSize?
            /// Whether the title card was inserted as real media (false =
            /// the segment is an empty black edit, no layer instruction).
            let titleHasMedia: Bool
        }
        let titleDur = CMTime(value: Int64(titleS * 1000), timescale: 1000)
        let freezeDur = CMTime(value: Int64(freezeS * 1000), timescale: 1000)
        var cursor = CMTime.zero
        var audioCursor = CMTime.zero

        // Generated stills (intro card, title cards, freeze frames, outro),
        // retained for the whole export — AVAssetTrack.asset is a WEAK
        // reference, the same trap as the source clips — and deleted from
        // tmp once the export returns.
        //
        // Why these are MEDIA and not CALayers: every layer's `contents`
        // stays resident in the offline CoreAnimation renderer for the
        // entire export, and its per-frame cost scales with them. Bisected
        // on device with MERGE_SELFTEST over 30 clips (a 441 s film): the
        // full layer tree died at 25 % with -11847 ← -16101 ("Operation
        // Interrupted"), dropping the freeze layers moved it to 80 %, and
        // both `noca` (no animation tool) and `nogaps` (empty tree)
        // exported cleanly. So the overlays are rendered into short
        // two-frame H.264 segments instead, which lets a plain merge run
        // with NO animation tool at all — the configuration proven to
        // survive any length.
        var stillAssets: [AVURLAsset] = []
        defer {
            withExtendedLifetime(stillAssets) {}
            for a in stillAssets { try? FileManager.default.removeItem(at: a.url) }
        }
        /// Insert a generated still as real media at `at`, returning false
        /// when it couldn't be made (caller falls back to an empty edit).
        let videoRegion = CGSize(width: videoW, height: videoH)
        func insertStill(
            _ image: CGImage?, at: CMTime, duration: CMTime, name: String
        ) async -> Bool {
            guard let still = try? await makeStillAsset(
                    image: image, size: videoRegion,
                    durationS: CMTimeGetSeconds(duration), filename: name),
                  let track = try? await still.loadTracks(withMediaType: .video).first,
                  ((try? compVideo.insertTimeRange(
                      CMTimeRange(start: .zero, duration: duration),
                      of: track, at: at)) != nil)
            else { return false }
            stillAssets.append(still)
            return true
        }

        // "MovementLogger" gradient intro.
        var introHasMedia = false
        if introS > 0 {
            let introDur = CMTime(value: Int64(introS * 1000), timescale: 1000)
            introHasMedia = await insertStill(
                makeIntroImage(size: videoRegion), at: .zero,
                duration: introDur, name: "merge_intro.mov")
            if !introHasMedia {
                compVideo.insertEmptyTimeRange(
                    CMTimeRange(start: .zero, duration: introDur))
            }
            cursor = introDur
        }
        let introEnd = cursor

        var segments: [Segment] = []
        for l in loaded {
            let titleStart = cursor
            let clipStart = CMTimeAdd(titleStart, titleDur)
            var titleHasMedia = false
            if titleS > 0 {
                titleHasMedia = await insertStill(
                    makeTitleImage(startEpochMs: l.spec.startEpochMs, size: videoRegion),
                    at: titleStart, duration: titleDur,
                    name: "merge_title_\(segments.count).mov")
                if !titleHasMedia {
                    compVideo.insertEmptyTimeRange(
                        CMTimeRange(start: titleStart, duration: titleDur))
                }
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
            // Post-clip freeze: the clip's last frame, held and faded to
            // black. This is REAL MEDIA (a 2-frame H.264 still written to
            // tmp), not a CALayer holding the bitmap — the offline
            // CoreAnimation renderer keeps every layer's contents resident
            // for the whole export, so N full-region freeze bitmaps grow
            // without bound and iOS kills the export with -11847 ← -16101
            // ("Operation Interrupted"). Bisected on device with
            // MERGE_SELFTEST: 30 clips died at 25 %, and at 80 % with the
            // freeze layers removed — memory pressure, not a structural
            // fault. As media the frames stream off disk and the fade
            // becomes a native opacity ramp on the layer instruction.
            let freezeEnd = freezeS > 0 ? CMTimeAdd(clipEnd, freezeDur) : clipEnd
            var freezeSize: CGSize? = nil
            if freezeS > 0, !dbg.contains("nofreeze") {
                let fit = min(videoW / max(l.displayedW, 1),
                              videoH / max(l.displayedH, 1))
                let size = CGSize(width: evenDown(l.displayedW * fit),
                                  height: evenDown(l.displayedH * fit))
                if let frame = await lastFrameImage(
                       asset: l.asset, duration: l.duration, maxSize: size),
                   let still = try? await makeStillAsset(
                       image: frame, size: size, durationS: freezeS,
                       filename: "merge_freeze_\(segments.count).mov"),
                   let stillTrack = try? await still.loadTracks(
                       withMediaType: .video).first,
                   (try? compVideo.insertTimeRange(
                       CMTimeRange(start: .zero, duration: freezeDur),
                       of: stillTrack, at: clipEnd)) != nil {
                    stillAssets.append(still)
                    freezeSize = size
                }
            }
            // No freeze media (extraction/encode failed, or the knob is
            // set): fall back to the empty black edit the fade used to sit
            // on. Mid-timeline empty edits are preserved — only TRAILING
            // ones get dropped, and the last freeze is followed by the
            // outro anchor.
            if freezeS > 0, freezeSize == nil {
                compVideo.insertEmptyTimeRange(
                    CMTimeRange(start: clipEnd, end: freezeEnd))
            }
            segments.append(Segment(
                loaded: l, titleStart: titleStart, clipStart: clipStart,
                clipEnd: clipEnd, freezeEnd: freezeEnd, freezeSize: freezeSize,
                titleHasMedia: titleHasMedia))
            cursor = freezeEnd
        }

        // ----- 5 s logo outro after the last clip's fade-out. A trailing
        // EMPTY edit does not work here — AVFoundation silently drops empty
        // edits at the end of a composition track, so the film would just
        // end at the last clip (verified: 95.1 s instead of 100.1 s).
        // Freezing a frame of the last clip across the outro was tried and
        // is codec-dependent (a scaled 10-bit HEVC sample silently
        // truncated the export at the last clip). The outro is therefore a
        // SYNTHESIZED clip with the logo already drawn into it — no clip
        // content is touched, and no layer is needed to show the logo.
        let outroStart = cursor
        var outroHasMedia = false
        if outroSecs > 0 {
            let outroDur = CMTime(value: Int64(outroSecs * 1000), timescale: 1000)
            outroHasMedia = await insertStill(
                makeOutroImage(size: videoRegion), at: outroStart,
                duration: outroDur, name: "merge_outro.mov")
            if outroHasMedia {
                cursor = CMTimeAdd(outroStart, outroDur)
            }
            // No outro media — the film simply ends after the last clip.
        }

        let totalDur = cursor
        let totalS = CMTimeGetSeconds(totalDur)

        progress(0.01)

        // ----- Video composition instructions: [intro] then per clip
        // [title gap][clip][freeze], tiling [0, totalDur] exactly (shared
        // CMTime boundaries).
        var instructions: [AVMutableVideoCompositionInstruction] = []
        // Card segments (intro / title / outro) are full-video-region
        // stills written at exactly videoW×videoH, so they need no
        // transform — an identity layer instruction composites them at the
        // origin, which IS the video region at the top of the canvas.
        func cardInstruction(from: CMTime, to: CMTime, hasMedia: Bool)
            -> AVMutableVideoCompositionInstruction {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = CMTimeRange(start: from, end: to)
            inst.backgroundColor = UIColor.black.cgColor
            if hasMedia {
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
                li.setTransform(.identity, at: from)
                inst.layerInstructions = [li]
            } else {
                inst.layerInstructions = []   // just the black background
            }
            return inst
        }
        if introS > 0 {
            instructions.append(cardInstruction(
                from: .zero, to: introEnd, hasMedia: introHasMedia))
        }
        for seg in segments {
            if titleS > 0 {
                instructions.append(cardInstruction(
                    from: seg.titleStart, to: seg.clipStart,
                    hasMedia: seg.titleHasMedia))
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
            // NO fade during the clip — it plays completely unfaded ("play
            // every movie till the end and then add phase out over 3
            // seconds"); the fade lives on the post-clip freeze layer.
            inst.layerInstructions = [li]
            instructions.append(inst)

            // Post-clip freeze region. With freeze media inserted, the held
            // frame is composited from the track and faded by a native
            // opacity ramp; without it the segment is plain black.
            if freezeS > 0 {
                let freeze = AVMutableVideoCompositionInstruction()
                freeze.timeRange = CMTimeRange(start: seg.clipEnd, end: seg.freezeEnd)
                freeze.backgroundColor = UIColor.black.cgColor
                if let fs = seg.freezeSize {
                    let fli = AVMutableVideoCompositionLayerInstruction(
                        assetTrack: compVideo)
                    // The still is written at its fitted size, so it only
                    // needs centering in the video region at the top of the
                    // canvas — no rotation (the frame was extracted upright).
                    fli.setTransform(CGAffineTransform(
                        translationX: (videoW - fs.width) / 2,
                        y: (videoH - fs.height) / 2), at: seg.clipEnd)
                    fli.setOpacityRamp(
                        fromStartOpacity: 1.0, toEndOpacity: 0.0,
                        timeRange: CMTimeRange(start: seg.clipEnd, end: seg.freezeEnd))
                    freeze.layerInstructions = [fli]
                } else {
                    freeze.layerInstructions = []
                }
                instructions.append(freeze)
            }
        }

        // Outro instruction: the logo is drawn INTO the outro still, so an
        // identity layer instruction is all it needs.
        if outroSecs > 0, CMTimeCompare(totalDur, outroStart) > 0 {
            instructions.append(cardInstruction(
                from: outroStart, to: totalDur, hasMedia: outroHasMedia))
        }

        // ----- CALayer tree: ONLY the per-clip panel stacks. Intro, title
        // cards, freeze frames and the outro are all real media now — see
        // the composition loop for why (layer contents stay resident for
        // the whole export and sink long merges). A plain merge therefore
        // ends up with an EMPTY tree, and the animation tool is skipped
        // entirely below.
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        parentLayer.backgroundColor = UIColor.black.cgColor
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame   // FULL parent — no inner letterbox
        parentLayer.addSublayer(videoLayer)

        for seg in segments {
            let clipStartS = CMTimeGetSeconds(seg.clipStart)
            let clipEndS = CMTimeGetSeconds(seg.clipEnd)
            let clipDurS = max(clipEndS - clipStartS, 0.001)

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
        // Attach the CoreAnimation tool ONLY when there is something in the
        // tree (i.e. sensor panels). A plain merge now renders every card
        // from media, so it skips the tool altogether — the configuration
        // that survived a 441 s / 30-clip export on device while every
        // layer-tree variant was interrupted at 25–80 %.
        if !dbg.contains("noca"), parentLayer.sublayers?.count ?? 0 > 1 {
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
        // Stamp the film with the EARLIEST clip's capture date. Without it
        // the merged .mov has no creation_time at all, so re-picking it
        // (e.g. merging yesterday's films into a bigger one) lands in the
        // "no capture date — using file date" fallback.
        if let earliest = clips.map({ $0.startEpochMs }).filter({ $0 > 0 }).min() {
            session.metadata = CompositeExporter.creationDateMetadata(epochMs: earliest)
        }

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
                + CompositeExporter.interruptedHint(session.error)
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

    /// The clip's last frame as an upright CGImage. Tolerant seek (up to
    /// 1 s before the nominal end) so HEVC B-frame tails can't fail it.
    /// `maxSize` caps the decode to the size the freeze is encoded at —
    /// no point decoding a 4K frame to re-encode it at 1080.
    private static func lastFrameImage(
        asset: AVURLAsset, duration: CMTime, maxSize: CGSize
    ) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxSize
        gen.requestedTimeToleranceAfter = .zero
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        let target = CMTimeMaximum(
            .zero, CMTimeSubtract(duration, CMTime(value: 1, timescale: 30)))
        return try? await gen.image(at: target).image
    }

    /// Render `draw` over an opaque black frame of `size`. The card images
    /// (intro / title / outro) are encoded straight into short video
    /// segments, so they are full frames rather than transparent strips.
    private static func cardImage(
        size: CGSize, _ draw: (CGContext) -> Void
    ) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // export-only render — avoid the device-scale trap
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            draw(ctx.cgContext)
        }.cgImage
    }

    /// Outro card: the Pump Tsüri logo centered on black at ~45 % of the
    /// frame height.
    private static func makeOutroImage(size: CGSize) -> CGImage? {
        guard let logo = UIImage(named: "RideLogo") else {
            return cardImage(size: size) { _ in }
        }
        var h = size.height * outroLogoHeightFrac
        var w = logo.size.height > 0 ? h * (logo.size.width / logo.size.height) : h
        if w > size.width * 0.8 {
            let shrink = size.width * 0.8 / w
            w *= shrink
            h *= shrink
        }
        return cardImage(size: size) { _ in
            logo.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2,
                                 width: w, height: h))
        }
    }

    /// Intro lettering: "MovementLogger", bold, centered, sized so the text
    /// spans ~86% of the frame width, each letter colored along the logo
    /// gradient (orange → teal → blue → purple, per-letter interpolation).
    private static func makeIntroImage(size canvasSize: CGSize) -> CGImage? {
        let text = "MovementLogger"
        func gradientColor(_ t: Double) -> UIColor {
            let clamped = max(0, min(t, 1))
            let scaled = clamped * Double(introStops.count - 1)
            let seg = min(Int(scaled), introStops.count - 2)
            let f = CGFloat(scaled - Double(seg))
            let a = introStops[seg]
            let b = introStops[seg + 1]
            return UIColor(
                red: (a.r + (b.r - a.r) * f) / 255.0,
                green: (a.g + (b.g - a.g) * f) / 255.0,
                blue: (a.b + (b.b - a.b) * f) / 255.0,
                alpha: 1
            )
        }
        // Size the font so the rendered string spans ~86% of the width.
        let refFont = UIFont.systemFont(ofSize: 100, weight: .bold)
        let refW = (text as NSString).size(withAttributes: [.font: refFont]).width
        guard refW > 0 else { return nil }
        let fontSize = 100.0 * canvasSize.width * 0.86 / refW
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        let attr = NSMutableAttributedString(
            string: text, attributes: [.font: font])
        let n = text.count
        for i in 0..<n {
            let t = n > 1 ? Double(i) / Double(n - 1) : 0
            attr.addAttribute(
                .foregroundColor, value: gradientColor(t),
                range: NSRange(location: i, length: 1))
        }
        let textSize = attr.size()
        return cardImage(size: canvasSize) { _ in
            attr.draw(at: CGPoint(x: (canvasSize.width - textSize.width) / 2,
                                  y: (canvasSize.height - textSize.height) / 2))
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
        try await makeStillAsset(
            image: nil, size: CGSize(width: 64, height: 64),
            durationS: durationS, filename: "merge_outro_anchor.mov")
    }

    /// Write `image` (or black when nil) as a tiny two-frame H.264 clip of
    /// `durationS` seconds into tmp, and return it as an asset.
    ///
    /// Two frames — one at 0 and one near the end — make the track's media
    /// genuinely span the duration while the decoder simply holds the first
    /// frame throughout. Used for the outro timeline anchor AND for every
    /// post-clip freeze: as media the frame streams off disk, whereas a
    /// CALayer holding the same bitmap stays resident in the offline
    /// CoreAnimation renderer for the entire export.
    private static func makeStillAsset(
        image: CGImage?, size: CGSize, durationS: Double, filename: String
    ) async throws -> AVURLAsset {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        let w = Int(max(size.width.rounded(), 2))
        let h = Int(max(size.height.rounded(), 2))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw MergeExportError.exportFailed(
                "still writer: \(writer.error?.localizedDescription ?? "startWriting failed")")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw MergeExportError.exportFailed("still writer: no pixel buffer pool")
        }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else {
            throw MergeExportError.exportFailed("still writer: no pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0, CVPixelBufferGetDataSize(pb))
            if let image, let ctx = CGContext(
                data: base, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
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
                "still writer: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
        }
        return AVURLAsset(url: url)
    }

    /// Title card: recording date (dd.MM.yyyy) above start time (HH:mm:ss),
    /// local timezone, white, centered on black.
    private static func makeTitleImage(
        startEpochMs: Int64, size canvasSize: CGSize
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
        let blockH = dateSize.height + gap + timeSize.height
        let top = (canvasSize.height - blockH) / 2
        return cardImage(size: canvasSize) { _ in
            (dateText as NSString).draw(
                at: CGPoint(x: (canvasSize.width - dateSize.width) / 2, y: top),
                withAttributes: dateAttrs
            )
            (timeText as NSString).draw(
                at: CGPoint(x: (canvasSize.width - timeSize.width) / 2,
                            y: top + dateSize.height + gap),
                withAttributes: timeAttrs
            )
        }
    }
}
