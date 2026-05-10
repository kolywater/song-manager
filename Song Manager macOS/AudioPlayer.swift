import AVFoundation
import Observation

@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var currentURL: URL?
    var trackName: String = ""
    var bounceFiles: [URL] = []
    var isLooping = false
    var errorMessage: String?

    private var avPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var scopedRootURL: URL?

    func play(url bounceURL: URL, rootURL: URL) {
        // Stop any existing playback first
        stop()

        // Start security-scoped access for the root folder
        guard rootURL.startAccessingSecurityScopedResource() else {
            errorMessage = "Cannot access file — permission denied"
            return
        }
        scopedRootURL = rootURL

        // Scan for all bounce files while we have scoped access
        let scanResult = ProjectScanner.scan(rootURL: rootURL)
        bounceFiles = scanResult.bounceFiles

        startPlayback(bounceURL)
    }

    func switchTrack(to url: URL) {
        // Reuse existing scoped access — just swap the file
        avPlayer?.stop()
        stopTimer()
        startPlayback(url)
    }

    private func startPlayback(_ bounceURL: URL) {
        guard let player = try? AVAudioPlayer(contentsOf: bounceURL) else {
            errorMessage = "Could not play \"\(bounceURL.lastPathComponent)\""
            if scopedRootURL != nil, currentURL == nil {
                // First play failed — clean up scoped access
                scopedRootURL?.stopAccessingSecurityScopedResource()
                scopedRootURL = nil
                bounceFiles = []
            }
            return
        }

        avPlayer = player
        player.delegate = self
        currentURL = bounceURL
        trackName = bounceURL.deletingPathExtension().lastPathComponent
        duration = player.duration
        currentTime = 0

        player.play()
        isPlaying = true
        startTimer()
    }

    func togglePlayPause() {
        guard let player = avPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        avPlayer?.currentTime = time
        currentTime = time
    }

    func stop() {
        avPlayer?.stop()
        avPlayer = nil
        stopTimer()
        isPlaying = false
        currentTime = 0
        duration = 0
        currentURL = nil
        trackName = ""
        bounceFiles = []

        if let root = scopedRootURL {
            root.stopAccessingSecurityScopedResource()
            scopedRootURL = nil
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.avPlayer else { return }
            self.currentTime = player.currentTime
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            if isLooping {
                player.currentTime = 0
                player.play()
                currentTime = 0
            } else {
                isPlaying = false
                currentTime = 0
                stopTimer()
            }
        }
    }
}
