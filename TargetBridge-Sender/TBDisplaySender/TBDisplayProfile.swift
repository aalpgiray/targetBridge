import Foundation

struct TBDisplayProfileSettings: Equatable {
    let captureSource: TBDisplayCaptureSource
    let capturePreset: TBDisplayCapturePreset
    let matchRenderToStream: Bool
    let audioEnabled: Bool

    /// Whether live stream settings still match this profile.
    ///
    /// Decides if a stored profile may be re-applied. Once the user has changed
    /// the codec, the source or the render matching by hand, the profile is a
    /// stale preset rather than an instruction, and re-applying it silently
    /// discards their choice -- which is exactly what made the app appear to
    /// forget its settings every time a stream stopped.
    ///
    /// `audioEnabled` is deliberately excluded: it is toggled independently of a
    /// profile (the audio add-on owns it), so including it would make an
    /// unrelated change look like divergence.
    func matchesStreamSettings(captureSource: TBDisplayCaptureSource,
                               capturePreset: TBDisplayCapturePreset,
                               matchRenderToStream: Bool) -> Bool {
        self.captureSource == captureSource
            && self.capturePreset == capturePreset
            && self.matchRenderToStream == matchRenderToStream
    }
}

enum TBDisplayProfile: String, CaseIterable, Identifiable, Codable {
    case work5K
    case lowLatency
    case presentation

    var id: String { rawValue }

    var settings: TBDisplayProfileSettings {
        switch self {
        case .work5K:
            return TBDisplayProfileSettings(
                captureSource: .extendedDesktop,
                capturePreset: .native5k,
                matchRenderToStream: true,
                audioEnabled: false
            )
        case .lowLatency:
            return TBDisplayProfileSettings(
                captureSource: .desktopMirror,
                capturePreset: .smooth1440p60,
                matchRenderToStream: false,
                audioEnabled: false
            )
        case .presentation:
            return TBDisplayProfileSettings(
                captureSource: .desktopMirror,
                capturePreset: .standard1440p,
                matchRenderToStream: false,
                audioEnabled: true
            )
        }
    }
}
