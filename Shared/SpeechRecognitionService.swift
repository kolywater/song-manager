import Foundation
import Speech
import AVFoundation

@Observable
@MainActor
final class SpeechRecognitionService {
    static let shared = SpeechRecognitionService()

    private(set) var isRecording: Bool = false
    private(set) var transcript: String = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    enum SpeechError: Error {
        case permissionDenied
        case recognizerUnavailable
        case audioEngineFailure
    }

    func requestPermissions() async -> Bool {
        let speechAuth = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechAuth == .authorized else { return false }
        // Microphone permission. iOS exposes AVAudioApplication; macOS
        // uses AVCaptureDevice.requestAccess.
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    func start() throws {
        guard !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        transcript = ""
        task?.cancel()
        task = nil

        // AVAudioSession is iOS-only. macOS routes audio through the
        // shared system mixer with no app-level session category.
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        #if !targetEnvironment(simulator)
        // On-device models aren't reliably present in the simulator, so
        // fall back to server-side recognition there.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        #endif
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                NSLog("[SpeechRecognition] task error: \(error)")
            }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    if self.isRecording { self.cleanup() }
                }
            }
        }

        isRecording = true
    }

    /// Stops the engine and returns the final transcript (trimmed).
    @discardableResult
    func stop() -> String {
        let final = transcript
        cleanup()
        return final.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        cleanup()
    }

    private func cleanup() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }
}
