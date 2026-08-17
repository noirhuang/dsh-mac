import Foundation

// MARK: - dsh 传输层：HTTP POST /api + 双 WS 下行事件流（自动重连）
// 载体为 Unix Domain Socket（NWConnection 手写实现，见 UDSNetwork.swift），零 TCP 端口。

public enum DSHConnectionState: Equatable, Sendable {
    case stopped
    case connecting
    case connected
    case reconnecting
}

public struct DSHRpcError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { "[\(code)] \(message)" }
}

public actor DSHTransport {
    public let socketPath: String

    public private(set) var state: DSHConnectionState = .stopped
    private var stateHandlers: [@Sendable (DSHConnectionState) -> Void] = []
    private var connectedHandlers: [@Sendable () -> Void] = []

    public typealias FrameEvent = (method: String, payload: JSONValue, rpcId: String)
    private var frameContinuations: [UUID: AsyncStream<FrameEvent>.Continuation] = [:]

    private var loopTask: Task<Void, Never>?
    private var generation = 0
    private var failGenerationContinuation: CheckedContinuation<Void, Never>?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: 订阅

    public func frames() -> AsyncStream<FrameEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            frameContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFrameSink(id) }
            }
        }
    }

    private func removeFrameSink(_ id: UUID) {
        frameContinuations[id] = nil
    }

    public func onStateChange(_ handler: @escaping @Sendable (DSHConnectionState) -> Void) {
        stateHandlers.append(handler)
    }

    public func onConnected(_ handler: @escaping @Sendable () -> Void) {
        connectedHandlers.append(handler)
    }

    // MARK: 单次调用

    public func call(_ method: String, payload: [String: JSONValue] = [:]) async throws -> JSONValue {
        let rpcId = UUID().uuidString
        let body: JSONValue = .object([
            "type": .string("client-request"),
            "rpcId": .string(rpcId),
            "method": .string(method),
            "payload": .object(payload),
        ])
        let wire = try JSONEncoder().encode(body)
        let resp = try await udsHTTPCall(socketPath: socketPath, path: "/api/\(method)", body: wire)
        guard resp.status == 200 else {
            throw DSHRpcError(code: "internal", message: "HTTP \(resp.status)")
        }
        let decoded = try JSONDecoder().decode(DSHWireResponse.self, from: resp.data)
        guard decoded.rpcId == rpcId else {
            throw DSHRpcError(code: "internal", message: "rpcId mismatch for \(method)")
        }
        if decoded.result.ok, let value = decoded.result.value {
            return value
        }
        let err = decoded.result.error
        throw DSHRpcError(code: err?.code ?? "internal", message: err?.message ?? "unknown error")
    }

    /// 应答 answerable server-request（approval/question）：POST /api/respond
    public func respond(rpcId: String, value: JSONValue) async throws {
        let body: JSONValue = .object([
            "type": .string("client-response"),
            "rpcId": .string(rpcId),
            "result": .object(["ok": .bool(true), "value": value]),
        ])
        let wire = try JSONEncoder().encode(body)
        let resp = try await udsHTTPCall(socketPath: socketPath, path: "/api/respond", body: wire)
        guard resp.status == 200 else {
            throw DSHRpcError(code: "internal", message: "respond HTTP \(resp.status)")
        }
    }

    /// 探测 socket 上是否已有可用服务（带超时，冷启动时 socket 不存在不能挂起）
    public nonisolated static func probe(socketPath: String) async -> Bool {
        let t = DSHTransport(socketPath: socketPath)
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await t.call("host.describe")
                    return true
                } catch { return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: 连接循环

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { await runLoop() }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        generation += 1
        setState(.stopped)
    }

    private func runLoop() async {
        var attempt = 0
        setState(.connecting)
        while !Task.isCancelled {
            generation += 1
            let gen = generation
            let healthy = await runGeneration(gen)
            if Task.isCancelled { break }
            if healthy {
                attempt = 0
                setState(.connected)
                connectedHandlers.forEach { $0() }
                await suspensionUntilGenerationFails(gen)
            }
            if Task.isCancelled || gen != generation { break }
            setState(.reconnecting)
            attempt += 1
            let cap = min(10_000, 500 * Int(pow(2, Double(max(0, attempt - 1)))))
            let delayNs = UInt64(max(200, cap / 2 + Int.random(in: 0...(cap / 2))) * 1_000_000)
            try? await Task.sleep(nanoseconds: delayNs)
        }
    }

    private func runGeneration(_ gen: Int) async -> Bool {
        // 就绪握手：describe 可达
        guard (try? await call("host.describe")) != nil else { return false }

        let sinks = frameContinuations
        let emit: @Sendable (String) -> Void = { text in
            guard let data = text.data(using: .utf8),
                  let frame = try? JSONDecoder().decode(DSHWireFrame.self, from: data)
            else { return }
            if frame.payload["type"]?.stringValue == "stream/error" { return }
            for cont in sinks.values { cont.yield((frame.method, frame.payload, frame.rpcId)) }
        }
        let muxClose: @Sendable () -> Void = { [weak self] in
            Task { await self?.failGenerationFromStream(gen) }
        }

        // 双 WS 下行流（泵在独立任务；任一断流 → 本代失败）
        let mux = udsWebSocketStream(socketPath: socketPath, path: "/api/events.mux", onText: emit, onClose: muxClose)
        let host = udsWebSocketStream(socketPath: socketPath, path: "/api/events.host", onText: emit, onClose: muxClose)

        // 保存以便 stop 时取消
        streamTasks = [mux, host]
        return true
    }

    private var streamTasks: [Task<Void, Never>] = []

    private func failGenerationFromStream(_ gen: Int) {
        streamTasks.forEach { $0.cancel() }
        streamTasks.removeAll()
        failGeneration(gen)
    }

    private func suspensionUntilGenerationFails(_ gen: Int) async {
        await withCheckedContinuation { cont in
            if gen != generation {
                cont.resume()
            } else {
                failGenerationContinuation = cont
            }
        }
    }

    private func failGeneration(_ gen: Int) {
        guard gen == generation else { return }
        generation += 1
        failGenerationContinuation?.resume()
        failGenerationContinuation = nil
    }

    private func setState(_ s: DSHConnectionState) {
        guard state != s else { return }
        state = s
        stateHandlers.forEach { $0(s) }
    }
}
