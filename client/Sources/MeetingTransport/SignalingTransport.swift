import Foundation
import Network

public enum SignalingState: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case failed(String)
}

public final class SignalingTransport {
    public var onMessage: (([String: Any]) -> Void)?
    public var onStateChange: ((SignalingState) -> Void)?

    private let queue = DispatchQueue(label: "meeting.tcp.signaling")
    private var connection: NWConnection?
    private var receiveBuffer = Data()

    public init() {}

    public func connect(host: String, port: UInt16) {
        disconnect()
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
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

    public func send(_ body: [String: Any]) {
        guard let connection,
              JSONSerialization.isValidJSONObject(body),
              var data = try? JSONSerialization.data(withJSONObject: body) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onStateChange?(.failed(error.localizedDescription))
            }
        })
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        onStateChange?(.idle)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4096
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data {
                self.receiveBuffer.append(data)
                self.consumeLines()
            }
            if let error {
                self.onStateChange?(.failed(error.localizedDescription))
                return
            }
            if isComplete {
                self.onStateChange?(.failed("服务器关闭了信令连接"))
                return
            }
            self.receiveNext(on: connection)
        }
    }

    private func consumeLines() {
        while let newline = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer[..<newline]
            receiveBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let body = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any] else { continue }
            onMessage?(body)
        }
        if receiveBuffer.count > 4096 {
            receiveBuffer.removeAll()
            onStateChange?(.failed("信令消息超过长度限制"))
        }
    }
}

