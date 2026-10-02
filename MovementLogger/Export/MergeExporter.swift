import Foundation
import AVFoundation
import UIKit

/// Merge N clips (chronological order) into one film:
///
///   [first clip's first frame held 3 s, "MovementLogger" title over it]
///   [title card 2.5 s] [clip 1, complete] [last-frame freeze fades out 3 s] …
///   [title card 2.5 s] [clip N, complete] [last-frame freeze fades out 3 s]
///   [foil "pumping" outro 3 s — over sky→sea, fading in/out of black]
///
/// The film OPENS on a 3 s freeze of the first clip's first frame with the
/// "MovementLogger" lettering floating semi-transparently over it (each
/// letter colored along the logo gradient orange → teal → blue → purple),
/// so the title reads over the actual footage rather than a black card, then
/// the film plays. It falls back to lettering on solid black when that frame
/// can't be extracted. It CLOSES with the foil icon PUMPING — rocking about
/// its wings (cadence + amplitudes mapped from Ayano's pumping footage) over
/// a sky→sea gradient, fading in from the black the last clip's freeze leaves
/// and back out to black to end the film. Each
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
/// When `backgroundMusic` is supplied the picked audio track is added as a
/// second audio track, looped to fill the whole film and faded in/out, mixed
/// UNDER the clips' own audio at `musicVolume` (0…1). `muteClipAudio` drops
/// the footage sound so the music carries the film alone — handy over
/// wind-noisy foil clips. The music source is decoded from a local file the
/// user picked; nothing is downloaded (App Store Guideline 5.2.3).
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
    /// Foil-logo "pumping" outro closing the film — ONCE, after the last
    /// clip's fade-out (not per clip). The foil icon rocks about its wings
    /// over a sky→sea gradient, mapped from Ayano's pumping footage.
    private static let outroS: Double = 3.0
    /// Pumping-outro motion, matched from the source pumping footage.
    private static let pumpFps: Int = 30
    private static let pumpPeriodS: Double = 1.05     // ~3 pumps over 3 s
    private static let pumpPitchDeg: Double = 11.0    // rock amplitude (°)
    private static let pumpHeaveFrac: Double = 0.021  // vertical bob (of H)
    private static let pumpSquash: Double = 0.035     // compress/extend
    private static let pumpLogoHeightFrac: CGFloat = 0.55  // foil size (of H)

    /// One source clip, loaded once for the whole export.
    private struct Loaded {
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

    static func export(
        clips: [MergeClipSpec],
        panelKinds: [CompositeExporter.PanelKind],
        backgroundMusic: URL? = nil,
        musicVolume: Float = 0.35,
        muteClipAudio: Bool = false,
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


        // ----- Two-phase, RESUMABLE render (v1.0.65).
        //
        // iOS revokes the GPU from any app that leaves the foreground, and
        // the video compositor needs it — so an export session carrying a
        // video composition is interrupted (-11847) the moment the user
        // switches to WhatsApp mid-merge. Before, the whole film was ONE
        // session and an interruption threw away every rendered minute
        // ("the merge process is gone and I have to start from 0 again").
        //
        // Now each clip is rendered into its own CHUNK file —
        // [title][clip][freeze-fade] (+ its panel stack) at the full canvas
        // — and kept in Caches/MergeWork, keyed by the clip's identity and
        // the render settings. A chunk that already exists is skipped, so a
        // re-run after an interruption continues from the last finished
        // clip with nothing re-encoded. The final ASSEMBLY pass stitches
        // intro + chunks + outro (+ music) with NO video composition — a
        // plain decode/encode that doesn't need the compositor — and the
        // chunks are deleted once the film is written. Peak memory also
        // drops: one clip's sources are live at a time, not fifty.
        let videoRegion = CGSize(width: videoW, height: videoH)
        let titleDur = CMTime(value: Int64(titleS * 1000), timescale: 1000)
        let freezeDur = CMTime(value: Int64(freezeS * 1000), timescale: 1000)
        let totalClipS = loaded.reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
        // Progress budget: chunk rendering by clip seconds, assembly as a
        // flat fraction of that (a re-encode without compositing is a few
        // times faster than the composited pass).
        let assemblyWeight = max(0.35 * totalClipS, 1.0)
        let totalWork = totalClipS + assemblyWeight
        var workDone = 0.0

        let workDir = chunkWorkDir()
        try? FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true)
        let settingsKey = "\(Int(videoW))x\(Int(videoH))|\(panelKinds.map { "\($0.rawValue)" }.joined(separator: ","))|\(muteClipAudio)|\(titleS)|\(freezeS)|\(dbg.sorted().joined(separator: ","))"

        struct Chunk {
            let url: URL
            let loaded: Loaded
        }
        var chunks: [Chunk] = []
        var chunkAssets: [AVURLAsset] = []
        defer { withExtendedLifetime(chunkAssets) {} }

        for (i, l) in loaded.enumerated() {
            let key = chunkKey(
                clipURL: l.spec.url, startEpochMs: l.spec.startEpochMs,
                durationMs: Int64(CMTimeGetSeconds(l.duration) * 1000),
                hasPanels: l.spec.panelInputs != nil, settings: settingsKey)
            let chunkURL = workDir.appendingPathComponent("seg_\(key).mov")
            let clipS = CMTimeGetSeconds(l.duration)
            if chunkIsComplete(chunkURL) {
                // Already rendered by an earlier (interrupted) run — reuse.
                chunks.append(Chunk(url: chunkURL, loaded: l))
                workDone += clipS
                progress(0.01 + 0.98 * workDone / totalWork)
                continue
            }
            let baseDone = workDone
            try await renderChunk(
                l, index: i, to: chunkURL,
                videoW: videoW, videoH: videoH, outputSize: outputSize,
                panelSize: panelSize, panelKinds: panelKinds,
                titleDur: titleDur, freezeDur: freezeDur,
                titleS: titleS, freezeS: freezeS,
                muteClipAudio: muteClipAudio, dbg: dbg
            ) { p in
                progress(0.01 + 0.98 * (baseDone + p * clipS) / totalWork)
            }
            chunks.append(Chunk(url: chunkURL, loaded: l))
            workDone += clipS
        }

        // ----- Assembly: intro + chunks + outro on one video track, clip
        // audio passed through, music looped underneath. No video
        // composition: every segment is already at outputSize, upright.
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw MergeExportError.exportFailed("could not add video track") }
        var compAudio: AVMutableCompositionTrack? = nil
        var audioCursor = CMTime.zero
        var stillAssets: [AVURLAsset] = []
        defer {
            withExtendedLifetime(stillAssets) {}
            for a in stillAssets { try? FileManager.default.removeItem(at: a.url) }
        }
        var musicAssets: [AVURLAsset] = []
        defer { withExtendedLifetime(musicAssets) {} }
        var cursor = CMTime.zero

        // Intro over the first clip's first frame — rendered at the FULL
        // output size (video region + black panel band) so it needs no
        // transform in the plain assembly.
        var musicCredit: String? = nil
        if let musicURL = backgroundMusic, musicVolume > 0 {
            musicCredit = await musicCreditString(musicURL)
        }
        if introS > 0 {
            let introDur = CMTime(value: Int64(introS * 1000), timescale: 1000)
            var introBg: CGImage? = nil
            var introBgRect = CGRect(origin: .zero, size: videoRegion)
            if let first = loaded.first {
                let fit = min(videoW / max(first.displayedW, 1),
                              videoH / max(first.displayedH, 1))
                let fw = evenDown(first.displayedW * fit)
                let fh = evenDown(first.displayedH * fit)
                introBgRect = CGRect(x: (videoW - fw) / 2, y: (videoH - fh) / 2,
                                     width: fw, height: fh)
                introBg = await firstFrameImage(
                    asset: first.asset, maxSize: CGSize(width: fw, height: fh))
            }
            let introImg = makeIntroImage(
                size: videoRegion, background: introBg,
                backgroundRect: introBgRect, musicCredit: musicCredit)
            if let still = try? await makeStillAsset(
                   image: padToCanvas(introImg, canvas: outputSize),
                   size: outputSize, durationS: introS, filename: "merge_intro.mov"),
               let track = try? await still.loadTracks(withMediaType: .video).first,
               (try? compVideo.insertTimeRange(
                   CMTimeRange(start: .zero, duration: introDur),
                   of: track, at: .zero)) != nil {
                stillAssets.append(still)
                cursor = introDur
            }
        }

        for chunk in chunks {
            let asset = AVURLAsset(url: chunk.url)
            chunkAssets.append(asset)
            guard let v = try? await asset.loadTracks(withMediaType: .video).first,
                  let dur = try? await asset.load(.duration),
                  CMTimeGetSeconds(dur) > 0 else {
                // A chunk that won't load is stale/corrupt — drop it so the
                // next run re-renders it, and fail this one loudly.
                try? FileManager.default.removeItem(at: chunk.url)
                throw MergeExportError.exportFailed(
                    "rendered segment unreadable: \(chunk.url.lastPathComponent) — tap Merge again")
            }
            try compVideo.insertTimeRange(
                CMTimeRange(start: .zero, duration: dur), of: v, at: cursor)
            if let a = try? await asset.loadTracks(withMediaType: .audio).first,
               let aRange = try? await a.load(.timeRange),
               CMTimeGetSeconds(aRange.duration) > 0 {
                if compAudio == nil {
                    compAudio = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let at = compAudio {
                    let dst = CMTimeAdd(cursor, aRange.start)
                    if CMTimeCompare(audioCursor, dst) < 0 {
                        at.insertEmptyTimeRange(CMTimeRange(start: audioCursor, end: dst))
                    }
                    let aDur = CMTimeMinimum(aRange.duration, CMTimeSubtract(dur, aRange.start))
                    try? at.insertTimeRange(
                        CMTimeRange(start: aRange.start, duration: aDur), of: a, at: dst)
                    audioCursor = CMTimeAdd(dst, aDur)
                }
            }
            cursor = CMTimeAdd(cursor, dur)
        }

        // Pumping-foil outro, rendered at the full output size.
        if outroSecs > 0 {
            let outroDur = CMTime(value: Int64(outroSecs * 1000), timescale: 1000)
            if let pump = try? await makeVideoAsset(
                   size: outputSize, durationS: outroSecs, fps: pumpFps,
                   filename: "merge_pump_outro.mov",
                   frame: { i, n in
                       padToCanvas(pumpFrameImage(i, n, size: videoRegion), canvas: outputSize)
                   }),
               let track = try? await pump.loadTracks(withMediaType: .video).first,
               (try? compVideo.insertTimeRange(
                   CMTimeRange(start: .zero, duration: outroDur),
                   of: track, at: cursor)) != nil {
                stillAssets.append(pump)
                cursor = CMTimeAdd(cursor, outroDur)
            }
        }

        let totalDur = cursor
        let totalS = CMTimeGetSeconds(totalDur)
        guard totalS > 0.05 else {
            throw MergeExportError.exportFailed("assembled film is empty")
        }

        // ----- Background music (optional) — unchanged design: a second
        // audio track looped over the film, faded in/out, under the clips.
        var musicMix: AVMutableAudioMix? = nil
        if let musicURL = backgroundMusic, !dbg.contains("noaudio"), totalS > 0.1 {
            let musicAsset = AVURLAsset(url: musicURL)
            musicAssets.append(musicAsset)
            if let mTrack = try? await musicAsset.loadTracks(withMediaType: .audio).first,
               let mRange = try? await mTrack.load(.timeRange),
               CMTimeGetSeconds(mRange.duration) > 0.05,
               let bg = composition.addMutableTrack(
                   withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                var at = CMTime.zero
                while CMTimeCompare(at, totalDur) < 0 {
                    let remaining = CMTimeSubtract(totalDur, at)
                    let piece = CMTimeMinimum(mRange.duration, remaining)
                    if CMTimeGetSeconds(piece) <= 0.001 { break }
                    do {
                        try bg.insertTimeRange(
                            CMTimeRange(start: mRange.start, duration: piece),
                            of: mTrack, at: at)
                    } catch { break }
                    at = CMTimeAdd(at, piece)
                }
                let vol = max(0, min(musicVolume, 1))
                let params = AVMutableAudioMixInputParameters(track: bg)
                if totalS > 4.0 {
                    let fadeIn = 1.0, fadeOut = 1.5
                    let inT = CMTime(seconds: fadeIn, preferredTimescale: 600)
                    params.setVolumeRamp(
                        fromStartVolume: 0, toEndVolume: vol,
                        timeRange: CMTimeRange(start: .zero, duration: inT))
                    params.setVolume(vol, at: inT)
                    params.setVolumeRamp(
                        fromStartVolume: vol, toEndVolume: 0,
                        timeRange: CMTimeRange(
                            start: CMTime(seconds: totalS - fadeOut, preferredTimescale: 600),
                            duration: CMTime(seconds: fadeOut, preferredTimescale: 600)))
                } else {
                    params.setVolume(vol, at: .zero)
                }
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                musicMix = mix
            }
        }

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
        session.shouldOptimizeForNetworkUse = true
        if let earliest = clips.map({ $0.startEpochMs }).filter({ $0 > 0 }).min() {
            session.metadata = CompositeExporter.creationDateMetadata(epochMs: earliest)
        }
        if let musicMix { session.audioMix = musicMix }

        let assemblyBase = workDone
        let poller = CompositeExporter.ProgressPoller(session: session) { p in
            progress(0.01 + 0.98 * (assemblyBase + max(0, min(p, 1)) * assemblyWeight) / totalWork)
        }
        poller.start()
        await session.export()
        poller.stop()

        switch session.status {
        case .completed:
            // The film exists — the chunks have served their purpose.
            for c in chunks { try? FileManager.default.removeItem(at: c.url) }
            progress(1.0)
        case .failed:
            throw MergeExportError.exportFailed(
                describeError(session.error) + CompositeExporter.interruptedHint(session.error))
        case .cancelled:
            throw MergeExportError.exportFailed("cancelled")
        default:
            throw MergeExportError.exportFailed("status \(session.status.rawValue)")
        }
    }

    // -------------------------------------------------------------------------
    //  Chunk rendering (one clip → one file at the full canvas)
    // -------------------------------------------------------------------------

    /// Where finished per-clip segments wait for assembly. Caches (not
    /// Documents): invisible in the Files app, and iOS may reclaim it under
    /// storage pressure — a reclaimed chunk simply re-renders.
    static func chunkWorkDir() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("MergeWork", isDirectory: true)
    }

    /// Delete leftover segments older than `maxAgeDays` (abandoned merges).
    static func sweepChunkWorkDir(maxAgeDays: Double = 3) {
        let dir = chunkWorkDir()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        for f in files {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if m < cutoff || f.pathExtension == "part" {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    /// Stable identity for a rendered segment: the clip (capture time +
    /// duration + file name — PhotosPicker copies change path per import,
    /// so the path itself is NOT part of the key) and everything that
    /// changes its pixels.
    private static func chunkKey(
        clipURL: URL, startEpochMs: Int64, durationMs: Int64,
        hasPanels: Bool, settings: String
    ) -> String {
        let s = "\(clipURL.lastPathComponent)|\(startEpochMs)|\(durationMs)|\(hasPanels)|\(settings)"
        // FNV-1a 64-bit — deterministic across launches (Hasher is seeded).
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// A segment counts as finished only once it was renamed from `.part`
    /// — an interrupted export leaves a truncated `.part` behind, never a
    /// complete-looking file.
    private static func chunkIsComplete(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.int64Value > 4096 else { return false }
        return true
    }

    /// Letterbox a video-region image onto the full output canvas (black
    /// below, where the panel band sits), so cards need no transform in
    /// the plain assembly pass. Identity when there is no panel band.
    private static func padToCanvas(_ image: CGImage?, canvas: CGSize) -> CGImage? {
        guard let image else { return nil }
        if CGFloat(image.width) == canvas.width.rounded(),
           CGFloat(image.height) == canvas.height.rounded() { return image }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let out = UIGraphicsImageRenderer(size: canvas, format: fmt).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            UIImage(cgImage: image).draw(in: CGRect(
                x: (canvas.width - CGFloat(image.width)) / 2, y: 0,
                width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return out.cgImage
    }

    private static func renderChunk(
        _ l: Loaded, index: Int, to chunkURL: URL,
        videoW: CGFloat, videoH: CGFloat, outputSize: CGSize, panelSize: CGSize,
        panelKinds: [CompositeExporter.PanelKind],
        titleDur: CMTime, freezeDur: CMTime, titleS: Double, freezeS: Double,
        muteClipAudio: Bool, dbg: Set<String>,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        func evenDown(_ v: CGFloat) -> CGFloat {
            let r = max(v.rounded(), 2)
            return r - r.truncatingRemainder(dividingBy: 2)
        }
        let videoRegion = CGSize(width: videoW, height: videoH)
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw MergeExportError.exportFailed("could not add video track") }
        var stillAssets: [AVURLAsset] = []
        defer {
            withExtendedLifetime(stillAssets) {}
            for a in stillAssets { try? FileManager.default.removeItem(at: a.url) }
        }

        // [title]
        var titleHasMedia = false
        if titleS > 0 {
            if let still = try? await makeStillAsset(
                   image: makeTitleImage(startEpochMs: l.spec.startEpochMs, size: videoRegion),
                   size: videoRegion, durationS: titleS,
                   filename: "merge_title_\(index).mov"),
               let t = try? await still.loadTracks(withMediaType: .video).first,
               (try? compVideo.insertTimeRange(
                   CMTimeRange(start: .zero, duration: titleDur), of: t, at: .zero)) != nil {
                stillAssets.append(still)
                titleHasMedia = true
            } else {
                compVideo.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: titleDur))
            }
        }
        // [clip] — FULL range, never trimmed.
        let clipStart = titleS > 0 ? titleDur : .zero
        try compVideo.insertTimeRange(
            CMTimeRange(start: .zero, duration: l.duration), of: l.videoTrack, at: clipStart)
        let clipEnd = CMTimeAdd(clipStart, l.duration)
        if !dbg.contains("noaudio"), !muteClipAudio, let a = l.audioTrack,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            if CMTimeCompare(clipStart, .zero) > 0 {
                compAudio.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: clipStart))
            }
            let aDur = CMTimeMinimum(l.audioRange.duration, l.duration)
            try? compAudio.insertTimeRange(
                CMTimeRange(start: l.audioRange.start, duration: aDur), of: a, at: clipStart)
        }
        // [freeze] — last frame held and faded to black (real media).
        var freezeEnd = clipEnd
        var freezeSize: CGSize? = nil
        if freezeS > 0, !dbg.contains("nofreeze") {
            let fit = min(videoW / max(l.displayedW, 1), videoH / max(l.displayedH, 1))
            let size = CGSize(width: evenDown(l.displayedW * fit),
                              height: evenDown(l.displayedH * fit))
            if let frame = await lastFrameImage(asset: l.asset, duration: l.duration, maxSize: size),
               let still = try? await makeStillAsset(
                   image: frame, size: size, durationS: freezeS,
                   filename: "merge_freeze_\(index).mov"),
               let t = try? await still.loadTracks(withMediaType: .video).first,
               (try? compVideo.insertTimeRange(
                   CMTimeRange(start: .zero, duration: freezeDur), of: t, at: clipEnd)) != nil {
                stillAssets.append(still)
                freezeSize = size
                freezeEnd = CMTimeAdd(clipEnd, freezeDur)
            }
            // No freeze media: the chunk just ends on the clip (a trailing
            // empty edit would be dropped by AVFoundation anyway).
        }
        let totalDur = freezeEnd
        let totalS = CMTimeGetSeconds(totalDur)

        // ----- Instructions tiling [0, totalDur].
        var instructions: [AVMutableVideoCompositionInstruction] = []
        if titleS > 0 {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = CMTimeRange(start: .zero, end: clipStart)
            inst.backgroundColor = UIColor.black.cgColor
            if titleHasMedia {
                let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
                li.setTransform(.identity, at: .zero)
                inst.layerInstructions = [li]
            }
            instructions.append(inst)
        }
        do {
            let inst = AVMutableVideoCompositionInstruction()
            inst.timeRange = CMTimeRange(start: clipStart, end: clipEnd)
            inst.backgroundColor = UIColor.black.cgColor
            let li = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            var xform = l.preferredTransform
            let rotated = CGRect(origin: .zero, size: l.naturalSize).applying(l.preferredTransform)
            xform = xform.concatenating(CGAffineTransform(
                translationX: -rotated.origin.x, y: -rotated.origin.y))
            let w = abs(rotated.width), h = abs(rotated.height)
            if w > 0, h > 0 {
                let s = min(videoW / w, videoH / h)
                xform = xform.concatenating(CGAffineTransform(scaleX: s, y: s))
                xform = xform.concatenating(CGAffineTransform(
                    translationX: (videoW - w * s) / 2, y: (videoH - h * s) / 2))
            }
            li.setTransform(xform, at: clipStart)
            li.setOpacity(1.0, at: clipStart)
            inst.layerInstructions = [li]
            instructions.append(inst)
        }
        if let fs = freezeSize {
            let freeze = AVMutableVideoCompositionInstruction()
            freeze.timeRange = CMTimeRange(start: clipEnd, end: freezeEnd)
            freeze.backgroundColor = UIColor.black.cgColor
            let fli = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            fli.setTransform(CGAffineTransform(
                translationX: (videoW - fs.width) / 2, y: (videoH - fs.height) / 2), at: clipEnd)
            fli.setOpacityRamp(fromStartOpacity: 1.0, toEndOpacity: 0.0,
                               timeRange: CMTimeRange(start: clipEnd, end: freezeEnd))
            freeze.layerInstructions = [fli]
            instructions.append(freeze)
        }

        // ----- Panel stack for THIS clip only (CA tool attached only then).
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: outputSize)
        parentLayer.backgroundColor = UIColor.black.cgColor
        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)
        if !panelKinds.isEmpty, let inputs = l.spec.panelInputs {
            let clipStartS = CMTimeGetSeconds(clipStart)
            let clipEndS = CMTimeGetSeconds(clipEnd)
            let clipDurS = max(clipEndS - clipStartS, 0.001)
            let container = CALayer()
            container.frame = parentLayer.frame
            gateOpacity(container, fromS: clipStartS, toS: clipEndS, totalS: totalS)
            for (slot, kind) in panelKinds.enumerated() {
                let panel = CALayer()
                let yQuartz = CGFloat(panelKinds.count - 1 - slot) * CompositeExporter.panelHeight
                panel.frame = CGRect(origin: CGPoint(x: 0, y: yQuartz), size: panelSize)
                panel.isGeometryFlipped = true
                panel.contents = CompositeExporter.renderPanelImage(
                    index: kind.rawValue, size: panelSize, inputs: inputs)
                panel.contentsGravity = .resize
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
                            panelWidth: videoW, inputs: inputs)
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
                        dot.frame = CGRect(x: -dotR, y: -dotR, width: dotR * 2, height: dotR * 2)
                        dot.path = CGPath(
                            ellipseIn: CGRect(x: 0, y: 0, width: dotR * 2, height: dotR * 2),
                            transform: nil)
                        dot.fillColor = UIColor.systemRed.cgColor
                        let (xs, ys, keyTimes) = CompositeExporter.gpsDotValues(
                            durationS: clipDurS, panelSize: panelSize, inputs: inputs)
                        let anim = CAKeyframeAnimation(keyPath: "position")
                        anim.values = zip(xs, ys).map { NSValue(cgPoint: CGPoint(x: $0, y: $1)) }
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
                        durationS: clipDurS, inputs: inputs, beginOffsetS: clipStartS) {
                        panel.addSublayer(live)
                    }
                }
                container.addSublayer(panel)
            }
            parentLayer.addSublayer(container)
        }

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = outputSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        if !dbg.contains("nosdr") {
            videoComp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
            videoComp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
            videoComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        }
        if !dbg.contains("noca"), parentLayer.sublayers?.count ?? 0 > 1 {
            videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }
        videoComp.instructions = instructions

        // Write to `.part`, rename on success — see `chunkIsComplete`.
        let partURL = chunkURL.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partURL)
        try? FileManager.default.removeItem(at: chunkURL)
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality
        ) else { throw MergeExportError.exportFailed("could not create export session") }
        session.outputURL = partURL
        session.outputFileType = .mov
        if !dbg.contains("novc") { session.videoComposition = videoComp }
        let poller = CompositeExporter.ProgressPoller(session: session) { p in
            progress(max(0, min(p, 1)))
        }
        poller.start()
        await session.export()
        poller.stop()
        switch session.status {
        case .completed:
            try FileManager.default.moveItem(at: partURL, to: chunkURL)
        case .failed:
            try? FileManager.default.removeItem(at: partURL)
            var detail = describeError(session.error)
                + CompositeExporter.interruptedHint(session.error)
            let findings = validationFindings(videoComp, for: composition)
            if !findings.isEmpty {
                detail += " · composition invalid: " + findings.joined(separator: "; ")
            }
            throw MergeExportError.exportFailed("clip \(index + 1): " + detail)
        case .cancelled:
            try? FileManager.default.removeItem(at: partURL)
            throw MergeExportError.exportFailed("cancelled")
        default:
            try? FileManager.default.removeItem(at: partURL)
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

    /// The clip's first frame as an upright CGImage. Tolerant seek (up to
    /// 1 s after t=0) so a clip opening on a non-keyframe can't fail it.
    /// `maxSize` caps the decode to the size it will be drawn at — no point
    /// decoding a 4K frame to composite it behind the intro lettering.
    private static func firstFrameImage(
        asset: AVURLAsset, maxSize: CGSize
    ) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxSize
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        return try? await gen.image(at: .zero).image
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

    /// One frame of the foil "pumping" outro: the foil icon rocking about its
    /// wings + a synced vertical bob + squash, over a sky→sea gradient, with a
    /// fade-IN from black at the start (bridges the last clip's fade-to-black)
    /// and a fade-OUT to black at the end. `i` of `n` frames. The cadence and
    /// amplitudes are mapped from Ayano's pumping footage.
    ///
    /// Rendered in a native y-up `CGContext` (same transforms verified in the
    /// macOS preview) so `ctx.draw(logo,…)` composites the foil upright; the
    /// resulting photo-oriented CGImage streams through `makeVideoAsset` into
    /// the pixel buffer exactly like the freeze frames, so it exports upright.
    private static func pumpFrameImage(_ i: Int, _ n: Int, size: CGSize) -> CGImage? {
        let W = Int(size.width.rounded()), H = Int(size.height.rounded())
        guard W >= 2, H >= 2, let logoCG = clearLogo?.cgImage else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let fW = CGFloat(W), fH = CGFloat(H)

        // Sky → sea gradient (y-up: y = fH is the top of the frame).
        if let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0.74, green: 0.89, blue: 0.96, alpha: 1),   // sky
            CGColor(red: 0.42, green: 0.72, blue: 0.83, alpha: 1),   // horizon
            CGColor(red: 0.11, green: 0.34, blue: 0.50, alpha: 1),   // sea
        ] as CFArray, locations: [0, 0.52, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: fH),
                                   end: CGPoint(x: 0, y: 0), options: [])
        }

        let dur = Double(n) / Double(pumpFps)
        let secs = Double(i) / Double(pumpFps)
        let phase = (2.0 * Double.pi / pumpPeriodS) * secs

        // Foil geometry + pump motion (rock about the wings, bob, squash).
        let logoH = fH * pumpLogoHeightFrac
        let logoW = logoH   // square asset
        let logoRect = CGRect(x: (fW - logoW) / 2, y: (fH - logoH) / 2,
                              width: logoW, height: logoH)
        // Wings sit ~72 % down the asset; y-up pivot measured from the bottom.
        let pivot = CGPoint(x: logoRect.midX,
                            y: logoRect.minY + (1 - 0.72) * logoH)
        let theta = pumpPitchDeg * sin(phase) * .pi / 180.0
        let dy = -pumpHeaveFrac * Double(fH) * sin(phase)   // rise on nose-up
        let sy = 1.0 - pumpSquash * cos(phase)              // squash at compress

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(dy))               // heave
        ctx.translateBy(x: pivot.x, y: pivot.y)             // rock + squash
        ctx.rotate(by: CGFloat(theta))                      //   about the wings
        ctx.scaleBy(x: 1, y: CGFloat(sy))
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22,
                      color: UIColor.black.withAlphaComponent(0.35).cgColor)
        ctx.draw(logoCG, in: logoRect)
        ctx.restoreGState()

        // Fade in from black, then out to black.
        let fadeInS = 0.35, fadeOutS = 0.75
        var cover = 0.0
        if secs < fadeInS { cover = 1.0 - secs / fadeInS }
        else if secs > dur - fadeOutS { cover = (secs - (dur - fadeOutS)) / fadeOutS }
        if cover > 0.001 {
            ctx.setFillColor(UIColor.black.withAlphaComponent(
                CGFloat(max(0, min(cover, 1)))).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: fW, height: fH))
        }
        return ctx.makeImage()
    }

    /// Write a rendered frame sequence as an H.264 clip of `durationS` seconds
    /// at `fps` into tmp, returning it as an asset. `frame(i, n)` supplies the
    /// CGImage for frame i of n, drawn into the pixel buffer exactly like
    /// `makeStillAsset` (so a photo-oriented CGImage comes out upright). Used
    /// for the animated pumping outro; kept MEDIA so the export never needs
    /// the CoreAnimation tool.
    private static func makeVideoAsset(
        size: CGSize, durationS: Double, fps: Int, filename: String,
        frame: (Int, Int) -> CGImage?
    ) async throws -> AVURLAsset {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        let w = Int(max(size.width.rounded(), 2))
        let h = Int(max(size.height.rounded(), 2))
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw MergeExportError.exportFailed(
                "video writer: \(writer.error?.localizedDescription ?? "startWriting failed")")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw MergeExportError.exportFailed("video writer: no pixel buffer pool")
        }
        let n = max(Int((durationS * Double(fps)).rounded()), 1)
        for i in 0..<n {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(5))
            }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
            guard let pb = pbOut else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0, CVPixelBufferGetDataSize(pb))
                if let img = frame(i, n), let ctx = CGContext(
                    data: base, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                ) {
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime:
                CMTime(value: Int64(i), timescale: Int32(fps)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime:
            CMTime(seconds: durationS, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MergeExportError.exportFailed(
                "video writer: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
        }
        return AVURLAsset(url: url)
    }

    /// The Pump Tsüri logo with its flat near-white background knocked out to
    /// transparency, so it composites over footage (or black) as just the
    /// coloured foil — the raw `RideLogo` asset is an opaque 1024² app-icon
    /// square, which draws as a light box. Neutral-light pixels are cleared;
    /// saturated pixels (the foil) and dark neutral pixels (its edges/outline)
    /// are kept, with a feather so anti-aliased edges stay clean. Computed
    /// once (a one-shot ~1 MP pixel walk) and cached for the app session.
    private static let clearLogo: UIImage? = makeClearLogo()
    private static func makeClearLogo() -> UIImage? {
        guard let src = UIImage(named: "RideLogo")?.cgImage else { return nil }
        let w = src.width, h = src.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = max(0, min((x - a) / (b - a), 1))
            return t * t * (3 - 2 * t)
        }
        let out: CGImage? = buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = base.assumingMemoryBound(to: UInt8.self)
            let count = bytesPerRow * h
            var i = 0
            while i < count {
                let r = Float(p[i]), g = Float(p[i + 1]), b = Float(p[i + 2])
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let chroma = mx - mn
                // Keep coloured pixels (chroma) OR dark neutral pixels (the
                // thin outline / shading); clear neutral-light background.
                let a = max(smoothstep(8, 26, chroma),
                            1 - smoothstep(205, 240, mx))
                p[i]     = UInt8((r * a).rounded())
                p[i + 1] = UInt8((g * a).rounded())
                p[i + 2] = UInt8((b * a).rounded())
                p[i + 3] = UInt8((a * 255).rounded())
                i += 4
            }
            return ctx.makeImage()
        }
        return out.map { UIImage(cgImage: $0) }
    }

    /// Intro lettering: "MovementLogger", bold, centered, sized so the text
    /// spans ~86% of the frame width, each letter colored along the logo
    /// gradient (orange → teal → blue → purple, per-letter interpolation).
    ///
    /// When `background` is supplied it is drawn (into `backgroundRect`, black
    /// letterbox around it) UNDER the lettering, and the text is rendered
    /// semi-transparently with a soft dark shadow so the first video frame
    /// shows through while the title stays legible over arbitrary footage —
    /// the "title over the first image" opener. With no background it renders
    /// the lettering fully opaque on solid black (the legacy intro card).
    /// Title — artist for the intro credit: the track's embedded metadata,
    /// falling back to its filename (the user names tracks by song title).
    private static func musicCreditString(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        var title: String? = nil
        var artist: String? = nil
        if let md = try? await asset.load(.commonMetadata) {
            for item in md {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyTitle, let v = try? await item.load(.stringValue) {
                    title = v
                } else if key == .commonKeyArtist,
                          let v = try? await item.load(.stringValue) {
                    artist = v
                }
            }
        }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let t, !t.isEmpty {
            base = (a?.isEmpty == false) ? "\(t) — \(a!)" : t
        } else {
            base = url.deletingPathExtension().lastPathComponent
        }
        return base.isEmpty ? nil : "♫ \(base)"
    }

    private static func makeIntroImage(
        size canvasSize: CGSize, background: CGImage?, backgroundRect: CGRect,
        musicCredit: String? = nil
    ) -> CGImage? {
        let text = "MovementLogger"
        // Over footage the lettering is translucent so the frame reads
        // through it; on black it stays fully opaque.
        let textAlpha: CGFloat = background == nil ? 1.0 : 0.85
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
                alpha: textAlpha
            )
        }
        // Size the font so the rendered string spans ~86% of the width.
        let refFont = UIFont.systemFont(ofSize: 100, weight: .bold)
        let refW = (text as NSString).size(withAttributes: [.font: refFont]).width
        guard refW > 0 else { return nil }
        let fontSize = 100.0 * canvasSize.width * 0.86 / refW
        let font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        // Soft shadow keeps the translucent lettering readable over bright or
        // busy footage (a no-op on the solid-black fallback).
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = fontSize * 0.08
        shadow.shadowOffset = .zero
        let attr = NSMutableAttributedString(
            string: text, attributes: [.font: font, .shadow: shadow])
        let n = text.count
        for i in 0..<n {
            let t = n > 1 ? Double(i) / Double(n - 1) : 0
            attr.addAttribute(
                .foregroundColor, value: gradientColor(t),
                range: NSRange(location: i, length: 1))
        }
        let textSize = attr.size()
        // Optional music credit ("♫ Title — Artist"), drawn as a smaller
        // translucent line under the title.
        let creditAttr: NSAttributedString? = musicCredit.map { credit in
            let cShadow = NSShadow()
            cShadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
            cShadow.shadowBlurRadius = fontSize * 0.05
            cShadow.shadowOffset = .zero
            let cFont = UIFont.systemFont(ofSize: fontSize * 0.30, weight: .semibold)
            // Fit within ~90% of the width by shrinking if needed.
            var size = fontSize * 0.30
            var font = cFont
            var w = (credit as NSString).size(withAttributes: [.font: font]).width
            let maxW = canvasSize.width * 0.90
            while w > maxW, size > 8 {
                size -= 2
                font = UIFont.systemFont(ofSize: size, weight: .semibold)
                w = (credit as NSString).size(withAttributes: [.font: font]).width
            }
            return NSAttributedString(string: credit, attributes: [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                .shadow: cShadow,
            ])
        }
        let creditSize = creditAttr?.size() ?? .zero
        return cardImage(size: canvasSize) { _ in
            if let background {
                UIImage(cgImage: background).draw(in: backgroundRect)
            }
            let titleTop = (canvasSize.height - textSize.height) / 2
            attr.draw(at: CGPoint(x: (canvasSize.width - textSize.width) / 2, y: titleTop))
            if let creditAttr {
                creditAttr.draw(at: CGPoint(
                    x: (canvasSize.width - creditSize.width) / 2,
                    y: titleTop + textSize.height + canvasSize.height * 0.02))
            }
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
