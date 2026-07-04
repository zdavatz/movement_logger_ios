import Foundation

/// The newest box-firmware release on GitHub, with the direct download URL of
/// its `firmware-vX.Y.Z.bin` asset. Port of the desktop's
/// `stbox-viz-gui/src/update.rs::FirmwareRelease` — kept deliberately separate
/// from any app-store update path so the two update flows can never cross-wire.
struct FirmwareRelease: Equatable {
    /// Bare `X.Y.Z` (the `v` tag prefix stripped) — compare with `parseVersion`.
    let version: String
    let downloadURL: URL
}

/// Box-firmware update check: fetch the latest firmware release from GitHub and
/// download its `.bin`. Direct port of `movement_logger_desktop`'s
/// `update.rs` (`check_latest_firmware` / `download` / `parse_version`), using
/// `URLSession` instead of `reqwest`.
enum FirmwareUpdate {
    /// Firmware releases live in the *firmware* repo, separate from the app.
    private static let firmwareRepo = "zdavatz/movement_logger_firmware"
    private static let userAgent = "MovementLogger-iOS"

    /// Parse a semver-ish `"X.Y.Z"` into a comparable `(major, minor, patch)`
    /// tuple. Trailing non-digits on the patch are tolerated (e.g. `"0.0.29-rc"`
    /// → `(0, 0, 29)`). Returns `nil` when it isn't three dot-separated parts
    /// with numeric major/minor. Mirrors the desktop `parse_version`.
    static func parseVersion(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: ".", maxSplits: 2,
                            omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else { return nil }
        let patchDigits = parts[2].prefix { $0.isNumber }
        guard let patch = Int(patchDigits) else { return nil }
        return (major, minor, patch)
    }

    /// Query GitHub for the newest firmware release: the highest `vX.Y.Z` tag
    /// whose assets include one matching `firmware-v*.bin`. Returns `nil` on a
    /// network error, a missing asset, or no parseable release — the caller
    /// treats `nil` as "couldn't reach GitHub". Mirrors `check_latest_firmware`.
    static func checkLatest() async -> FirmwareRelease? {
        guard let url = URL(string:
            "https://api.github.com/repos/\(firmwareRepo)/releases?per_page=30")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let releases = try? JSONDecoder().decode([GithubRelease].self, from: data)
        else { return nil }

        var best: ((Int, Int, Int), FirmwareRelease)? = nil
        for r in releases {
            if r.prerelease { continue }
            guard r.tagName.hasPrefix("v") else { continue }
            let stripped = String(r.tagName.dropFirst())
            guard let v = parseVersion(stripped) else { continue }
            guard let asset = r.assets.first(where: {
                      $0.name.hasPrefix("firmware-v") && $0.name.hasSuffix(".bin")
                  }),
                  let dl = URL(string: asset.browserDownloadURL) else { continue }
            if best == nil || v > best!.0 {
                best = (v, FirmwareRelease(version: stripped, downloadURL: dl))
            }
        }
        return best?.1
    }

    /// Download a release asset (the firmware `.bin`) into memory. Returns `nil`
    /// on any transport error or an empty body. Mirrors the desktop `download`.
    static func download(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }

    // ---- GitHub Releases JSON (subset) --------------------------------------

    private struct GithubRelease: Decodable {
        let tagName: String
        let prerelease: Bool
        let assets: [GithubAsset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case prerelease
            case assets
        }
    }

    private struct GithubAsset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}
