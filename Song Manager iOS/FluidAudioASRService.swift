import Foundation
import AVFoundation
@preconcurrency import FluidAudio

/// Voice-note transcription backed by FluidAudio's true-streaming Parakeet
/// EOU 120M model (`StreamingModelVariant.parakeetEou320ms` — 320 ms
/// chunks for ~sub-second partial latency). Mirrors the call-site shape
/// of the old `SpeechRecognitionService` except that `start()` and
/// `stop()` are async (model load + final flush).
///
/// On first use the CoreML model downloads from HuggingFace into the
/// system cache (~150 MB). Subsequent launches reuse the cache.
@Observable
@MainActor
final class FluidAudioASRService {
    /// Shared instance so the model load only happens once per app
    /// session (and can be kicked off from app launch via `prepare()`
    /// before the user ever opens the player).
    static let shared = FluidAudioASRService()

    private(set) var isRecording: Bool = false
    /// True while the first-use model download/load is in flight.
    private(set) var isLoadingModel: Bool = false
    /// True only when the model files are not yet present on disk and we
    /// will actually pull from HuggingFace. False when warming up from
    /// the on-disk cache.
    private(set) var isDownloadingModel: Bool = false
    private(set) var transcript: String = ""
    /// Last error surfaced from the engine. Cleared on each new `start()`
    /// or via `clearError()`.
    private(set) var lastErrorMessage: String? = nil

    private let audioEngine = AVAudioEngine()
    private var manager: (any StreamingAsrManager)?
    private var modelsLoaded = false

    func requestPermissions() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Fire-and-forget warmup. Safe to call repeatedly; idempotent after
    /// the first successful load. Call from app launch so the model is
    /// resident before the user taps the mic.
    func prepare() {
        guard !modelsLoaded, !isLoadingModel else { return }
        Task { @MainActor in
            try? await loadModelsIfNeeded()
        }
    }

    private func loadModelsIfNeeded() async throws {
        guard !modelsLoaded else { return }
        if manager == nil {
            manager = StreamingModelVariant.parakeetEou320ms.createManager()
        }
        guard let manager else { return }
        isLoadingModel = true
        isDownloadingModel = !Self.cachedModelExists
        do {
            NSLog("[FluidAudioASR] loading Parakeet EOU 320ms (cached=\(!isDownloadingModel))")
            try await manager.loadModels()
            NSLog("[FluidAudioASR] model loaded")
            modelsLoaded = true
        } catch {
            NSLog("[FluidAudioASR] model load failed: \(error)")
            lastErrorMessage = "Model: \(error.localizedDescription)"
            isLoadingModel = false
            isDownloadingModel = false
            throw error
        }
        isLoadingModel = false
        isDownloadingModel = false
    }

    func clearError() {
        lastErrorMessage = nil
    }

    func start() async throws {
        guard !isRecording, !isLoadingModel else { return }
        transcript = ""
        lastErrorMessage = nil

        try await loadModelsIfNeeded()
        guard let manager else { return }
        // The model only needs reset between recordings; the very first
        // recording after load is already fresh.
        try? await manager.reset()

        // Partial transcripts are delivered via a callback. Hop to the
        // MainActor before writing to `transcript` so SwiftUI sees the
        // change on the main thread.
        await manager.setPartialTranscriptCallback { [weak self] text in
            Task { @MainActor in
                self?.transcript = text
            }
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[FluidAudioASR] audio session config failed: \(error)")
            lastErrorMessage = "Audio session: \(error.localizedDescription)"
            throw error
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // Tap at the input's native format; the engine resamples to 16
        // kHz mono internally. After appending each tap buffer, kick the
        // engine to consume any complete 320 ms chunks that have arrived.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [manager] buffer, _ in
            Task {
                do {
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()
                } catch {
                    NSLog("[FluidAudioASR] streaming append/process failed: \(error)")
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            NSLog("[FluidAudioASR] audio engine start failed: \(error)")
            lastErrorMessage = "Audio engine: \(error.localizedDescription)"
            throw error
        }
        isRecording = true
    }

    /// Stops the engine and returns the final transcript (trimmed).
    @discardableResult
    func stop() async -> String {
        guard isRecording else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        stopCapture()

        let final: String
        if let manager {
            final = (try? await manager.finish()) ?? transcript
        } else {
            final = transcript
        }
        isRecording = false
        deactivateSession()
        return final.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        lastErrorMessage = nil
        guard isRecording else { return }
        stopCapture()
        let manager = self.manager
        isRecording = false
        deactivateSession()
        Task {
            // No explicit cancel on the StreamingAsrManager protocol; a
            // reset() drops buffered audio + decoder state so the next
            // start() begins clean.
            try? await manager?.reset()
        }
    }

    private func stopCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    private func deactivateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    /// Mirrors `StreamingEouAsrManager.defaultCacheDirectory()` so we can
    /// tell at the call site whether the next `loadModels()` will hit the
    /// network or just warm up from disk. If the library ever moves its
    /// cache path this check silently degrades to "always say downloading"
    /// — annoying but not incorrect.
    private static var cachedModelExists: Bool {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let dir = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        // Any non-empty subfolder under the streaming root is enough to
        // indicate a previous successful download.
        return entries.contains { name in
            var isDir: ObjCBool = false
            let subPath = dir.appendingPathComponent(name).path
            return fm.fileExists(atPath: subPath, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
