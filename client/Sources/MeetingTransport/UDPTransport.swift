import Foundation
import MeetingCore
import Network

public enum TransportState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case failed(String)
}

public final class UDPTransport {
    public var onPacket: ((MediaPacket) -> Void)?
    public var onRTPPacket: ((RTPPacket) -> Void)?
    public var onStateChange: ((TransportState) -> Void)?

    private let queue = DispatchQueue(label: "meeting.udp.transport")
    private var connection: NWConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatSequence = UInt32.random(in: 0...UInt32.max)

    public init() {}

    public func connect(host: String, port: UInt16) {
        disconnect()
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        self.connection = connection
        onStateChange?(.connecting)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.onStateChange?(.ready)
            case .failed(let error):
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.idle)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveNext(on: connection)
    }

    public func send(_ packet: MediaPacket) {
        guard let connection else { return }
        do {
            let data = try PacketCodec.encode(packet)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.onStateChange?(.failed(error.localizedDescription))
                }
            })
        } catch {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    public func send(_ packet: RTPPacket) {
        guard let connection else { return }
        do {
            let data = try RTPCodec.encode(packet)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.onStateChange?(.failed(error.localizedDescription))
                }
            })
        } catch {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    public func startHeartbeat(sessionID: UInt32) {
        queue.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in
                guard let self, self.connection != nil else { return }
                self.heartbeatSequence &+= 1
                self.send(
                    MediaPacket(
                        type: .control,
                        sessionID: sessionID,
                        sequence: self.heartbeatSequence,
                        payload: Data(#"{"action":"heartbeat"}"#.utf8)
                    )
                )
            }
            self.heartbeatTimer = timer
            timer.resume()
        }
    }

    public func stopHeartbeat() {
        queue.async { [weak self] in
            self?.heartbeatTimer?.cancel()
            self?.heartbeatTimer = nil
        }
    }

    public func disconnect() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        onStateChange?(.idle)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                if data.starts(with: Data("MSH1".utf8)),
                   let packet = try? PacketCodec.decode(data) {
                    self.onPacket?(packet)
                } else if let packet = try? RTPCodec.decode(data) {
                    self.onRTPPacket?(packet)
                }
            }
            if let error {
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }
            self.receiveNext(on: connection)
        }
    }
}
