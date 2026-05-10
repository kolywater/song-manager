import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class AudioService {
    var nowPlaying: ProjectReference?
    var isPlaying: Bool = false
    var isLooping: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking: Bool = false

    init() {
        configureSession()
        setupRemoteCommands()
    }

    /// Show the player UI for a project before any audio is loaded.
    /// Use this to open the full player immediately while a streaming
    /// URL is being resolved.
    func preparePlayback(for project: ProjectReference) {
        detachTimeObserver()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player?.pause()
        player = nil
        nowPlaying = project
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func play(url: URL, project: ProjectReference, artwork: UIImage? = nil) {
        detachTimeObserver()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        self.player = newPlayer
        self.nowPlaying = project
        self.currentTime = 0
        self.duration = 0
        self.isPlaying = true

        attachTimeObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnd() }
        }

        Task { [weak self] in
            let asset = item.asset
            if let dur = try? await asset.load(.duration) {
                let seconds = dur.seconds
                if seconds.isFinite {
                    await MainActor.run { self?.duration = seconds }
                }
            }
        }

        newPlayer.play()
        updateNowPlayingInfo(artwork: artwork)
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlayingInfo(artwork: nil, preserve: true)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo(artwork: nil, preserve: true)
    }

    func resume() {
        player?.play()
        isPlaying = true
        updateNowPlayingInfo(artwork: nil, preserve: true)
    }

    func stop() {
        player?.pause()
        detachTimeObserver()
        player = nil
        nowPlaying = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func toggleLoop() {
        isLooping.toggle()
    }

    func skip(by delta: Double) {
        let target = max(0, min(duration > 0 ? duration : currentTime + delta, currentTime + delta))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        isSeeking = true
        currentTime = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                self.updateNowPlayingInfo(artwork: nil, preserve: true)
            }
        }
    }

    // MARK: - Private

    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            // Session config failure isn't fatal — log silently.
        }
    }

    private func attachTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if self.isSeeking { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = seconds
                self.updateNowPlayingInfo(artwork: nil, preserve: true)
            }
        }
    }

    private func detachTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func handleEnd() {
        if isLooping {
            seek(to: 0)
            player?.play()
            isPlaying = true
        } else {
            isPlaying = false
            currentTime = duration
        }
        updateNowPlayingInfo(artwork: nil, preserve: true)
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlayingInfo(artwork: UIImage?, preserve: Bool = false) {
        guard let project = nowPlaying else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = preserve ? (MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]) : [:]
        info[MPMediaItemPropertyTitle] = project.displayName
        info[MPMediaItemPropertyArtist] = "Adenel"
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
