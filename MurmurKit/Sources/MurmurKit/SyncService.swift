import Foundation
import Network
import os

private let log = Logger(subsystem: "com.murmur", category: "Sync")

@MainActor
public class SyncService: ObservableObject {
    private let serviceType = "_murmur._tcp"
    private let deviceName: String
    private var impl: SyncImpl?

    @Published public var isConnected = false
    @Published public var connectedPeers: [String] = []

    private var onReceive: (@MainActor (Transcription) -> Void)?
    private var onConnected: (@MainActor () -> Void)?

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    public func start(
        onReceive: @escaping @MainActor (Transcription) -> Void,
        onConnected: @escaping @MainActor () -> Void = {}
    ) {
        self.onReceive = onReceive
        self.onConnected = onConnected
        let impl = SyncImpl(serviceType: serviceType, deviceName: deviceName) { [weak self] transcription in
            Task { @MainActor in
                self?.onReceive?(transcription)
            }
        } onPeersChanged: { [weak self] peers in
            Task { @MainActor in
                let wasEmpty = self?.connectedPeers.isEmpty ?? true
                self?.connectedPeers = peers
                self?.isConnected = !peers.isEmpty
                if wasEmpty && !peers.isEmpty {
                    self?.onConnected?()
                }
            }
        }
        self.impl = impl
        impl.start()
    }

    public func send(_ transcription: Transcription) {
        impl?.send(transcription)
    }

    public func sendAll(_ transcriptions: [Transcription]) {
        for t in transcriptions {
            impl?.send(t)
        }
    }

    public func stop() {
        impl?.stop()
        impl = nil
        isConnected = false
        connectedPeers = []
    }
}

// Every device: advertises + browses + connects + accepts
private final class SyncImpl: Sendable {
    private let serviceType: String
    private let deviceName: String
    private let onReceive: @Sendable (Transcription) -> Void
    private let onPeersChanged: @Sendable ([String]) -> Void

    nonisolated(unsafe) private var listener: NWListener?
    nonisolated(unsafe) private var browser: NWBrowser?
    nonisolated(unsafe) private var connections: [(connection: NWConnection, name: String)] = []
    nonisolated(unsafe) private var knownEndpoints: Set<String> = []

    init(
        serviceType: String,
        deviceName: String,
        onReceive: @escaping @Sendable (Transcription) -> Void,
        onPeersChanged: @escaping @Sendable ([String]) -> Void
    ) {
        self.serviceType = serviceType
        self.deviceName = deviceName
        self.onReceive = onReceive
        self.onPeersChanged = onPeersChanged
    }

    func start() {
        startListener()
        startBrowser()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        connections.forEach { $0.connection.cancel() }
        connections.removeAll()
        knownEndpoints.removeAll()
    }

    func send(_ transcription: Transcription) {
        guard let data = try? JSONEncoder().encode(transcription) else { return }
        var length = UInt32(data.count).bigEndian
        let message = Data(bytes: &length, count: 4) + data

        for entry in connections where entry.connection.state == .ready {
            entry.connection.send(content: message, completion: .contentProcessed({ error in
                if let error { log.info("[Sync] Send error: \(error)") }
            }))
        }
    }

    // MARK: - Listener (accept incoming)

    private func startListener() {
        do {
            listener = try NWListener(using: .tcp)
            listener?.service = NWListener.Service(name: deviceName, type: serviceType)

            listener?.newConnectionHandler = { [weak self] connection in
                self?.addConnection(connection, name: "peer")
            }

            listener?.stateUpdateHandler = { [weak self] state in
                let name = self?.deviceName ?? ""
                switch state {
                case .ready:
                    log.info("[Sync] \(name) listening")
                case .failed(let error):
                    log.error("[Sync] \(name) listener failed: \(error)")
                case .cancelled:
                    log.info("[Sync] \(name) listener cancelled")
                default:
                    log.info("[Sync] \(name) listener state: \(String(describing: state))")
                }
            }

            listener?.start(queue: .main)
        } catch {
            log.info("[Sync] Listener failed: \(error)")
        }
    }

    // MARK: - Browser (discover and connect to peers)

    private func startBrowser() {
        browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                // Don't connect to self
                if case .service(let name, _, _, _) = result.endpoint, name == self.deviceName {
                    continue
                }

                var peerName = "peer"
                if case .service(let name, _, _, _) = result.endpoint {
                    peerName = name
                }

                let endpointID = "\(result.endpoint)"
                guard !self.knownEndpoints.contains(endpointID) else { continue }
                self.knownEndpoints.insert(endpointID)

                log.info("[Sync] found peer: \(peerName)")

                // To avoid duplicate connections (A→B and B→A),
                // only the device with the "lesser" name initiates
                if self.deviceName < peerName {
                    log.info("[Sync] initiating connection to \(peerName)")
                    let connection = NWConnection(to: result.endpoint, using: .tcp)
                    self.addConnection(connection, name: peerName)
                } else {
                    log.info("[Sync] waiting for \(peerName) to initiate")
                }
            }
        }

        browser?.stateUpdateHandler = { [weak self] state in
            let name = self?.deviceName ?? ""
            switch state {
            case .ready:
                log.info("[Sync] \(name) browsing")
            case .failed(let error):
                log.error("[Sync] \(name) browser failed: \(error)")
            case .cancelled:
                log.info("[Sync] \(name) browser cancelled")
            default:
                log.info("[Sync] \(name) browser state: \(String(describing: state))")
            }
        }

        browser?.start(queue: .main)
    }

    // MARK: - Connection management

    private func addConnection(_ connection: NWConnection, name: String) {
        let onPeers = onPeersChanged

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log.info("[Sync] connection ready to \(name)")
                onPeers(self?.connections.filter { $0.connection.state == .ready }.map(\.name) ?? [])
            case .failed(let error):
                log.error("[Sync] connection failed to \(name): \(error)")
                self?.removeConnection(connection)
            case .cancelled:
                log.info("[Sync] connection cancelled to \(name)")
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connections.append((connection: connection, name: name))
        connection.start(queue: .main)
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, _ in
            guard let self, let data, data.count == 4 else {
                if isComplete { self?.removeConnection(connection) }
                return
            }

            let length = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payload, _, isComplete, _ in
                if let payload,
                   let transcription = try? JSONDecoder().decode(Transcription.self, from: payload) {
                    log.info("[Sync] received transcription: \(transcription.text.prefix(50))")
                    self?.onReceive(transcription)
                } else {
                    log.error("[Sync] failed to decode payload (\(payload?.count ?? 0) bytes)")
                }

                if isComplete {
                    self?.removeConnection(connection)
                } else {
                    self?.receiveLoop(connection)
                }
            }
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0.connection === connection }
        connection.cancel()
        onPeersChanged(connections.filter { $0.connection.state == .ready }.map(\.name))
    }
}
