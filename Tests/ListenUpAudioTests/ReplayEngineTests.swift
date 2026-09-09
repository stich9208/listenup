import XCTest
import ListenUpAudio
import ListenUpDomain

final class ReplayEngineTests: XCTestCase {
    func testPlayheadIsIndependentFromRecordingHead() async {
        let span = AudioSpan(trackID: "microphone", relativePath: "audio/microphone/000001.caf", durationMs: 5_000, sessionStartMs: 0, sampleRate: 16_000, frameCount: 80_000, checksum: "x")
        let engine = ReplayEngine(spans: [span])
        await engine.seek(to: 2_000)
        await engine.update(spans: [span], liveHeadMs: 20_000)
        let initialPlayhead = await engine.playheadMs
        let recordingHead = await engine.recordingHead()
        XCTAssertEqual(initialPlayhead, 2_000)
        XCTAssertEqual(recordingHead, 20_000)
        await engine.rewind15Seconds()
        let rewoundPlayhead = await engine.playheadMs
        XCTAssertEqual(rewoundPlayhead, 0)
        await engine.returnToLive()
        let livePlayhead = await engine.playheadMs
        XCTAssertEqual(livePlayhead, 20_000)
    }
}
