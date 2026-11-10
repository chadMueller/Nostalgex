import AVFoundation
import Foundation

extension AppState {
    func beginPlaybackInformation(for item: PlexMediaItem, generation: Int) {
        guard generation == loadGeneration else { return }
        let backend: PlaybackInformation.Backend
        if isDemoMode {
            backend = .demo
        } else {
            switch backendKind {
            case .plex: backend = .plex
            case .jellyfin: backend = .jellyfin
            case .emby: backend = .emby
            }
        }
        playbackInformation = PlaybackInformation(
            generation: generation, backend: backend, qualityAtTune: StreamQuality.current,
            source: .init(videoCodec: isDemoMode ? nil : item.videoCodec, audioCodec: isDemoMode ? nil : item.audioCodec)
        )
    }

    @discardableResult
    func beginPlaybackInformationAttempt(generation: Int, attempt: Int, isDirectPlay: Bool,
                                         reason: PlaybackInformation.FallbackReason = .none,
                                         recoveryRequest: PlaybackInformation.RecoveryRequest? = nil,
                                         serverStream: PlaybackInformation.ServerStream? = nil) -> UUID? {
        guard isCurrentPlaybackAttempt(generation: generation, attempt: attempt) else { return nil }
        return playbackInformation?.beginAttempt(generation: generation,
            delivery: isDirectPlay ? .directPlay : .serverStream,
            reason: reason, recoveryRequest: recoveryRequest, serverStream: serverStream)
    }

    func markPlaybackInformationReady(for playerItem: AVPlayerItem, generation: Int, attempt: Int, attemptID: UUID?) {
        guard isCurrentPlaybackAttempt(generation: generation, attempt: attempt, playerItem: playerItem) else { return }
        playbackInformation?.markReady(generation: generation, attemptID: attemptID)
    }

    var playbackInformationRows: [PlaybackInformation.Row] {
        guard currentItem != nil, let information = playbackInformation,
              information.generation == loadGeneration else { return [] }
        let size = player?.currentItem?.presentationSize
        return information.rows(presentationWidth: size.map { Double($0.width) },
                                presentationHeight: size.map { Double($0.height) })
    }
}
