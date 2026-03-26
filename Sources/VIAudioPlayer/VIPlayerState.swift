import Foundation

/// Playback state of the audio player.
public enum VIPlayerState: Sendable, Equatable {
    case idle
    case preparing
    case ready
    case playing
    case paused
    case buffering
    case finished
    case failed(VIPlayerError)

    public static func == (lhs: VIPlayerState, rhs: VIPlayerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing), (.ready, .ready),
             (.playing, .playing), (.paused, .paused), (.buffering, .buffering),
             (.finished, .finished):
            return true
        case (.failed(let a), .failed(let b)):
            return a.localizedDescription == b.localizedDescription
        default:
            return false
        }
    }
}

/// Player errors.
public enum VIPlayerError: Error, Sendable {
    case sourceCreationFailed
    case decoderCreationFailed(Error)
    case decodingFailed(Error)
    case renderingFailed(Error)
    case seekFailed(Error)
    case networkError(Error)
    case unknown(Error)
}

/// Buffer state reported to delegates.
public enum VIBufferState: Sendable {
    case empty
    case buffering(progress: Float)
    case sufficient
    case full
}
