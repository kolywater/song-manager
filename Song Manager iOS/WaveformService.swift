import AVFoundation
import CoreMedia
import Foundation
import Observation

@MainActor
@Observable
final class WaveformService {
    private(set) var waveforms: [UUID: [Float]] = [:]
    private var inFlight: Set<UUID> = []

    static let barCount = 150

    func loadWaveform(for project: ProjectReference, audioURL: URL) async {
        if waveforms[project.id] != nil { return }
        if inFlight.contains(project.id) { return }

        if let cached = Self.loadFromDisk(id: project.id) {
            waveforms[project.id] = cached
            return
        }

        inFlight.insert(project.id)
        defer { inFlight.remove(project.id) }

        let bars = await Self.computeWaveform(from: audioURL, bars: Self.barCount)
        guard !bars.isEmpty else { return }

        Self.saveToDisk(bars: bars, id: project.id)
        waveforms[project.id] = bars
    }

    func invalidate(for id: UUID) {
        waveforms.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: Self.cacheURL(for: id))
    }

    // MARK: - Disk cache

    private static func cacheDir() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "Waveforms")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(for id: UUID) -> URL {
        cacheDir().appending(path: "\(id.uuidString).json")
    }

    private static func loadFromDisk(id: UUID) -> [Float]? {
        guard let data = try? Data(contentsOf: cacheURL(for: id)) else { return nil }
        return try? JSONDecoder().decode([Float].self, from: data)
    }

    private static func saveToDisk(bars: [Float], id: UUID) {
        guard let data = try? JSONEncoder().encode(bars) else { return }
        try? data.write(to: cacheURL(for: id), options: .atomic)
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
