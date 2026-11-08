import Foundation
import Network
import Sync

enum FrameType: UInt8, Sendable {
    case hello = 1, changes, syncDone, fileRequest, fileHeader, fileData, fileEnd, fileError, artworkRequest, artworkData
}

struct Frame: Sendable {
    var type: FrameType
    var payload: Data = Data()
}

public enum PeeringError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case timedOut
    case protocolViolation(String)
    case noPeer
    case fileFailed(String)
}

/// One TLS connection to a paired device, carrying length-prefixed frames: 4 bytes length, 1 byte type, payload.
final class FramedConnection: @unchecked Sendable {
    static let maxPayload = 16 * 1024 * 1024
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "musicam.peering.connection")

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// TLS with the pre-shared key; local network only; peer-to-peer Wi-Fi allowed when no shared network exists.
    static func parameters(key: PairingKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let secret = key.bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("musicam".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }

    /// Waits until the handshake finishes. A device holding a different key never gets past this.
    func start(timeout: TimeInterval = 6) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .failed(let error): if once.take() { continuation.resume(throwing: PeeringError.connectionFailed(error.localizedDescription)) }
                case .cancelled: if once.take() { continuation.resume(throwing: PeeringError.connectionFailed("cancelled")) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if once.take() {
                    connection.cancel()
                    continuation.resume(throwing: PeeringError.timedOut)
                }
            }
        }
    }

    func send(_ frame: Frame) async throws {
        var message = Data(capacity: 5 + frame.payload.count)
        message.append(contentsOf: withUnsafeBytes(of: UInt32(frame.payload.count).bigEndian) { Array($0) })
        message.append(frame.type.rawValue)
        message.append(frame.payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: message, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: PeeringError.connectionFailed(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Frame {
        let header = try await read(5)
        let length = Int(header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard length <= Self.maxPayload else { throw PeeringError.protocolViolation("frame too large") }
        guard let type = FrameType(rawValue: header[header.startIndex + 4]) else { throw PeeringError.protocolViolation("unknown frame") }
        let payload = length == 0 ? Data() : try await read(length)
        return Frame(type: type, payload: payload)
    }

    func cancel() {
        connection.cancel()
    }

    private func read(_ count: Int) async throws -> Data {
        var buffer = Data(capacity: count)
        while buffer.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: PeeringError.connectionFailed(error.localizedDescription)) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if isComplete { continuation.resume(throwing: PeeringError.connectionFailed("closed")) }
                    else { continuation.resume(returning: Data()) }
                }
            }
            buffer.append(chunk)
        }
        return buffer
    }
}

/// Lets exactly one of several racing callbacks resume a continuation.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
