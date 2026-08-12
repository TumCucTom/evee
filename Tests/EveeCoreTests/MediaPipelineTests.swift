import AVFoundation
import XCTest
@testable import EveeCore

final class MediaPipelineTests: XCTestCase {
    func testRetainedAudioPolicyRejectsEmptyFilesDirectoriesAndLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.caf")
        try Data().write(to: empty)
        let link = root.appendingPathComponent("linked.caf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: empty)

        XCTAssertThrowsError(try RetainedAudioPolicy.validate(empty))
        XCTAssertThrowsError(try RetainedAudioPolicy.validate(root))
        XCTAssertThrowsError(try RetainedAudioPolicy.validate(link))
    }

    func testRetainedAudioPolicyAcceptsReadableRegularFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("evee-audio-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("audio".utf8).write(to: file)

        XCTAssertNoThrow(try RetainedAudioPolicy.validate(file))
    }

    func testQwenConversionReadsLongAudioInBoundedChunks() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("evee-media-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let source = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let oneSecond = AVAudioFrameCount(source.sampleRate)
        do {
            let file = try AVAudioFile(forWriting: url, settings: source.settings)
            for second in 0..<4 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: oneSecond))
                buffer.frameLength = oneSecond
                for channelIndex in 0..<Int(source.channelCount) {
                    let channel = try XCTUnwrap(buffer.floatChannelData?[channelIndex])
                    for frame in 0..<Int(oneSecond) {
                        channel[frame] = sin(Float(frame + second * Int(oneSecond)) * 0.01) * 0.1
                    }
                }
                try file.write(from: buffer)
            }
        }

        let reader = try AudioSampleChunkReader(url: url, chunkDuration: 1)
        var chunks: [[Float]] = []
        while let chunk = try reader.next() { chunks.append(chunk) }

        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 16_128 })
        XCTAssertLessThanOrEqual(abs(chunks.reduce(0) { $0 + $1.count } - 64_000), 128)
    }

    func testSystemAudioSummaryReportsQualityAndSizeMetadata() {
        let url = URL(fileURLWithPath: "/tmp/system.m4a")
        let summary = SystemAudioCaptureSummary(
            outputURL: url,
            sampleCount: 120,
            droppedSampleCount: 3,
            byteCount: 4_096,
            duration: 8.5,
            wroteAudio: true
        )

        XCTAssertEqual(summary.outputURL, url)
        XCTAssertEqual(summary.sampleCount, 120)
        XCTAssertEqual(summary.droppedSampleCount, 3)
        XCTAssertEqual(summary.byteCount, 4_096)
        XCTAssertEqual(summary.duration, 8.5)
        XCTAssertTrue(summary.wroteAudio)
    }
}
