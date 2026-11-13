import Foundation
import MeetingCore

public final class AudioJitterBuffer {
    public var onPayload: ((UInt32, Data) -> Void)?

    private struct StreamState {
        var expectedSequence: UInt16?
        var pending: [UInt16: Data] = [:]
        var started = false
    }

    private let queue = DispatchQueue(label: "meeting.audio.jitter")
    private var streams: [UInt32: StreamState] = [:]
    private var timer: DispatchSourceTimer?

    public init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(60), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drainOneFrame() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
    }

    public func ingest(_ packet: RTPPacket) {
        guard packet.payloadType == .opus, !packet.payload.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            var state = streams[packet.ssrc] ?? StreamState()
            if state.expectedSequence == nil {
                state.expectedSequence = packet.sequence
            }
            state.pending[packet.sequence] = packet.payload
            if !state.started, state.pending.count >= 3 {
                state.started = true
            }
            streams[packet.ssrc] = state
        }
    }

    public func reset() {
        queue.sync {
            streams.removeAll()
        }
    }

    private func drainOneFrame() {
        for ssrc in Array(streams.keys) {
            guard var state = streams[ssrc],
                  state.started,
                  let expected = state.expectedSequence else { continue }
            if let payload = state.pending.removeValue(forKey: expected) {
                state.expectedSequence = expected &+ 1
                onPayload?(ssrc, payload)
            } else if !state.pending.isEmpty {
                state.expectedSequence = expected &+ 1
            } else {
                state.started = false
            }
            streams[ssrc] = state
        }
    }
}
