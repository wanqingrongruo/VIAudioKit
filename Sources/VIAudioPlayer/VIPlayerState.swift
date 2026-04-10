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
        case (.failed(let lhsErr), .failed(let rhsErr)):
            return lhsErr == rhsErr
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

extension VIPlayerError: Equatable {
    public static func == (lhs: VIPlayerError, rhs: VIPlayerError) -> Bool {
        switch (lhs, rhs) {
        case (.sourceCreationFailed, .sourceCreationFailed):
            return true
        case (.decoderCreationFailed(let l), .decoderCreationFailed(let r)):
            return (l as NSError) == (r as NSError)
        case (.decodingFailed(let l), .decodingFailed(let r)):
            return (l as NSError) == (r as NSError)
        case (.renderingFailed(let l), .renderingFailed(let r)):
            return (l as NSError) == (r as NSError)
        case (.seekFailed(let l), .seekFailed(let r)):
            return (l as NSError) == (r as NSError)
        case (.networkError(let l), .networkError(let r)):
            return (l as NSError) == (r as NSError)
        case (.unknown(let l), .unknown(let r)):
            return (l as NSError) == (r as NSError)
        default:
            return false
        }
    }
}

/// Buffer state reported to delegates.
public enum VIBufferState: Sendable {
    case empty
    case buffering(progress: Float)
    case sufficient
    case full
}
