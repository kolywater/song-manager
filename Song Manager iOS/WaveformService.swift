import AVFoundation
import CoreMedia
import Foundation
import Observation

@MainActor
@Observable
final class WaveformService {
    private(set) var waveforms: [UUID: [Float]] = [:]
    /// Which audio file the in-memory waveform for each project was built
    /// from. Lets us detect a version switch (same project, different
    /// bounce) and regenerate instead of returning a stale silhouette.
    private var loadedKeys: [UUID: String] = [:]
    /// Composite "id|key" so concurrent loads of two different versions of
    /// the same song don't block one another.
    private var inFlight: Set<String> = []

    static let barCount = 600
    /// Bumped when the bar count or analysis output format changes, so
    /// stale on-disk caches are skipped.
    private static let cacheVersion = "v2"

    /// `audioKey` identifies the specific bounce (its filename) so the
    /// waveform is cached per-version, not per-song. Without it, switching
    /// versions kept showing the first version's silhouette.
    func loadWaveform(for project: ProjectReference, audioURL: URL, audioKey: String) async {
        // Already have the waveform for *this* file — nothing to do.
        if waveforms[project.id] != nil, loadedKeys[project.id] == audioKey { return }
        let flightKey = "\(project.id.uuidString)|\(audioKey)"
        if inFlight.contains(flightKey) { return }

        if let cached = Self.loadFromDisk(id: project.id, key: audioKey) {
            waveforms[project.id] = cached
            loadedKeys[project.id] = audioKey
            return
        }

        inFlight.insert(flightKey)
        defer { inFlight.remove(flightKey) }

        let bars = await Self.computeWaveform(from: audioURL, bars: Self.barCount)
        guard !bars.isEmpty else { return }

        Self.saveToDisk(bars: bars, id: project.id, key: audioKey)
        waveforms[project.id] = bars
        loadedKeys[project.id] = audioKey
    }

    /// Drop just the cached waveform for a specific (project, audio file)
    /// pair. Used when the underlying audio bytes change but the filename
    /// stays the same (same-name bounce replacement) — the disk-cached
    /// silhouette would otherwise stay stale.
    func invalidate(for id: UUID, audioKey: String) {
        if loadedKeys[id] == audioKey {
            waveforms.removeValue(forKey: id)
            loadedKeys.removeValue(forKey: id)
        }
        try? FileManager.default.removeItem(at: Self.cacheURL(for: id, key: audioKey))
    }

    func invalidate(for id: UUID) {
        waveforms.removeValue(forKey: id)
        loadedKeys.removeValue(forKey: id)
        // Per-version caches all share the project-id prefix; drop them all.
        let dir = Self.cacheDir()
        let prefix = "\(id.uuidString)-"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for file in files where file.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: dir.appending(path: file))
            }
        }
    }

    // MARK: - Disk cache

    private static func cacheDir() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "Waveforms")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deterministic, filesystem-safe rendering of the audio key so the
    /// cache survives across launches (a hashed key wouldn't — Swift's
    /// Hasher is seeded per process).
    private static func sanitize(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    private static func cacheURL(for id: UUID, key: String) -> URL {
        cacheDir().appending(path: "\(id.uuidString)-\(sanitize(key))-\(cacheVersion).json")
    }

    private static func loadFromDisk(id: UUID, key: String) -> [Float]? {
        guard let data = try? Data(contentsOf: cacheURL(for: id, key: key)) else { return nil }
        return try? JSONDecoder().decode([Float].self, from: data)
    }

    private static func saveToDisk(bars: [Float], id: UUID, key: String) {
        guard let data = try? JSONEncoder().encode(bars) else { return }
        try? data.write(to: cacheURL(for: id, key: key), options: .atomic)
    }

    // MARK: - Audio analysis

    nonisolated static func computeWaveform(from url: URL, bars: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return []
        }
        guard let track = tracks.first else { return [] }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var allSamples: [Int16] = []
        allSamples.reserveCapacity(1_000_000)

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer
                )
                if status == noErr, let dataPointer {
                    let count = totalLength / MemoryLayout<Int16>.size
                    let int16Pointer = UnsafeRawPointer(dataPointer)
                        .assumingMemoryBound(to: Int16.self)
                    let bufferPointer = UnsafeBufferPointer(start: int16Pointer, count: count)
                    allSamples.append(contentsOf: bufferPointer)
                }
            }
            CMSampleBufferInvalidate(sampleBuffer)
        }

        guard reader.status == .completed, !allSamples.isEmpty else { return [] }

        let samplesPerBar = max(1, allSamples.count / bars)
        var result: [Float] = []
        result.reserveCapacity(bars)
        for i in 0..<bars {
            let start = i * samplesPerBar
            let end = min(start + samplesPerBar, allSamples.count)
            var maxAbs = 0
            for j in start..<end {
                let v = abs(Int(allSamples[j]))
                if v > maxAbs { maxAbs = v }
            }
            result.append(Float(maxAbs) / Float(Int16.max))
        }
        return result
    }
}
