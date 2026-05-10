import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

@MainActor
@Observable
final class AudioService {
    var nowPlaying: ProjectReference?
    var currentTrackFilename: String?
    var isPlaying: Bool = false
    var isLooping: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0

    /// Parsed version of the currently loaded bounce (e.g. [1, 3]),
    /// or nil if the filename hasn't been set or has no version suffix.
    var currentVersion: [Int]? {
        guard let filename = currentTrackFilename else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        return VersionService.parseVersion(fromStem: stem)
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking: Bool = false
    private var lastNowPlayingPush: Date = .distantPast

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
        currentTrackFilename = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// Load a project's audio into the player. Starts paused at 0 by
    /// default; pass `autoStart: true` to begin playing right away.
    func load(url: URL, project: ProjectReference, filename: String? = nil, artwork: UIImage? = nil, autoStart: Bool = false) {
        detachTimeObserver()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        self.player = newPlayer
        self.nowPlaying = project
        self.currentTrackFilename = filename
        self.currentTime = 0
        self.duration = 0
        self.isPlaying = autoStart
        if autoStart { newPlayer.play() }

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
        currentTrackFilename = nil
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
        // 20 Hz — fine-grained enough that the waveform playhead reads as
        // smooth motion, not stepwise. Lock-screen / now-playing info is
        // throttled to ~2 Hz inside the callback to avoid spamming
        // MPNowPlayingInfoCenter.
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if self.isSeeking { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = seconds
                let now = Date()
                if now.timeIntervalSince(self.lastNowPlayingPush) >= 0.5 {
                    self.lastNowPlayingPush = now
                    self.updateNowPlayingInfo(artwork: nil, preserve: true)
                }
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
