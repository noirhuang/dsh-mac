import Foundation
import Network

// MARK: - Unix Domain Socket 网络层
// macOS 的 URLSession 不支持 http+unix scheme（实测 "unsupported URL"），
// 用 NWConnection 手写 HTTP 短连接 + WebSocket 下行流客户端。

enum UDSNetworkError: Error, LocalizedError {
    case connectionFailed
    case badResponse
    var errorDescription: String? {
        switch self {
        case .connectionFailed: return "UDS 连接失败"
        case .badResponse: return "非法 HTTP 响应"
        }
    }
}

// MARK: HTTP 单次调用

/// 一次 UDS HTTP POST（Connection: close；服务端发完响应即关连接，读 EOF 判定结束）
func udsHTTPCall(socketPath: String, path: String, body: Data) async throws -> (status: Int, data: Data) {
    let head =
        "POST \(path) HTTP/1.1\r\n" +
        "Host: 127.0.0.1\r\n" +
        "content-type: application/json\r\n" +
        "content-length: \(body.count)\r\n" +
        "Connection: close\r\n\r\n"
    let raw = try await udsExchange(socketPath: socketPath, payload: Data(head.utf8) + body)
    return try parseHTTPResponse(raw)
}

// MARK: WebSocket 下行流

struct WSFrame {
    var opcode: UInt8
    var payload: Data
    var consumed: Int
}

/// UDS WebSocket：握手 + 帧循环，text 帧回调；断流时 onClose。返回的 Task 用于取消。
func udsWebSocketStream(socketPath: String, path: String, onText: @escaping (String) -> Void, onClose: @escaping @Sendable () -> Void) -> Task<Void, Never> {
    Task.detached {
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
        do {
            try await connWaitReady(conn)
            // 握手（Sec-WebSocket-Accept 服务端不校验我们本地实现）
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            let req =
                "GET \(path) HTTP/1.1\r\n" +
                "Host: 127.0.0.1\r\n" +
                "Upgrade: websocket\r\n" +
                "Connection: Upgrade\r\n" +
                "Sec-WebSocket-Key: \(key)\r\n" +
                "Sec-WebSocket-Version: 13\r\n\r\n"
            try await connSend(conn, data: Data(req.utf8))
            let handshake = try await connReceiveUntil(conn, delimiter: Data("\r\n\r\n".utf8), limit: 16 * 1024)
            let head = String(data: handshake, encoding: .utf8) ?? ""
            guard head.contains(" 101 ") else {
                conn.cancel()
                onClose()
                return
            }

            // 帧循环：只下行；文本帧回调；ping 自动回 pong；close 回敬
            var acc = Data()
            while !Task.isCancelled {
                let chunk = try await connReceive(conn)
                if chunk.isEmpty { break }
                acc.append(chunk)
                while let frame = nextWSFrame(acc) {
                    acc.removeSubrange(0..<frame.consumed)
                    switch frame.opcode {
                    case 0x1, 0x2, 0x0: // text / binary / continuation（协议只用 text）
                        if let text = String(data: frame.payload, encoding: .utf8) {
                            onText(text)
                        }
                    case 0x9: // ping
                        try await connSend(conn, data: wsFrame(opcode: 0xA, payload: frame.payload))
                    case 0x8: // close
                        try? await connSend(conn, data: wsFrame(opcode: 0x8, payload: Data()))
                        conn.cancel()
                        onClose()
                        return
                    default:
                        break
                    }
                }
            }
            conn.cancel()
            onClose()
        } catch {
            conn.cancel()
            onClose()
        }
    }
}

// MARK: NWConnection 基础

private func connWaitReady(_ conn: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        var resumed = false
        let timeout = DispatchWorkItem {
            if !resumed {
                resumed = true
                conn.cancel()
                cont.resume(throwing: UDSNetworkError.connectionFailed)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                timeout.cancel()
                if !resumed { resumed = true; cont.resume() }
            case .failed(let error):
                timeout.cancel()
                if !resumed { resumed = true; cont.resume(throwing: error) }
            case .cancelled:
                timeout.cancel()
                if !resumed { resumed = true; cont.resume(throwing: UDSNetworkError.connectionFailed) }
            default:
                break
            }
        }
        conn.start(queue: .global())
    }
}

private func connSend(_ conn: NWConnection, data: Data) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        conn.send(content: data, completion: .contentProcessed { error in
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        })
    }
}

private func connReceive(_ conn: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 512) { data, _, isComplete, error in
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: data ?? Data())
            }
            _ = isComplete
        }
    }
}

private func connReceiveUntil(_ conn: NWConnection, delimiter: Data, limit: Int) async throws -> Data {
    var acc = Data()
    while acc.count < limit {
        let chunk = try await connReceive(conn)
        if chunk.isEmpty { break }
        acc.append(chunk)
        if acc.range(of: delimiter) != nil { break }
    }
    return acc
}

/// 建连 → 发送 → 读到 EOF → 返回全部响应字节
private func udsExchange(socketPath: String, payload: Data) async throws -> Data {
    let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
    defer { conn.cancel() }
    try await connWaitReady(conn)
    try await connSend(conn, data: payload)
    var acc = Data()
    while true {
        let chunk = try await connReceive(conn)
        if chunk.isEmpty { break }
        acc.append(chunk)
    }
    return acc
}

// MARK: HTTP 解析

private func parseHTTPResponse(_ raw: Data) throws -> (status: Int, data: Data) {
    guard let headEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
        throw UDSNetworkError.badResponse
    }
    let headData = raw.subdata(in: 0..<headEnd.lowerBound)
    let bodyRaw = raw.subdata(in: headEnd.upperBound..<raw.count)
    guard let head = String(data: headData, encoding: .utf8),
          let statusLine = head.split(separator: "\r\n").first,
          statusLine.contains(" ")
    else { throw UDSNetworkError.badResponse }

    let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
    let lower = head.lowercased()
    if lower.contains("transfer-encoding: chunked") {
        return (status, decodeChunked(bodyRaw))
    }
    if let r = lower.range(of: "content-length:"), let lineEnd = lower[r.upperBound...].range(of: "\r\n") {
        let lenStr = lower[r.upperBound..<lineEnd.lowerBound].trimmingCharacters(in: .whitespaces)
        if let len = Int(lenStr), bodyRaw.count >= len {
            return (status, bodyRaw.prefix(len))
        }
    }
    return (status, bodyRaw)
}

private func decodeChunked(_ data: Data) -> Data {
    var out = Data()
    var cursor = 0
    let bytes = [UInt8](data)
    while cursor < bytes.count {
        guard let lineEnd = findCRLF(bytes, from: cursor) else { break }
        let sizeLine = String(bytes: bytes[cursor..<lineEnd], encoding: .utf8) ?? ""
        let hex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
        guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
        cursor = lineEnd + 2
        if size == 0 { break }
        guard cursor + size <= bytes.count else { break }
        out.append(contentsOf: bytes[cursor..<(cursor + size)])
        cursor += size + 2
    }
    return out
}

private func findCRLF(_ bytes: [UInt8], from: Int) -> Int? {
    var i = from
    while i + 1 < bytes.count {
        if bytes[i] == 13, bytes[i + 1] == 10 { return i }
        i += 1
    }
    return nil
}

// MARK: WebSocket 帧编解码

/// 从缓冲解析一个完整 WS 帧（服务端帧无 mask）；不足一帧返回 nil
private func nextWSFrame(_ buffer: Data) -> WSFrame? {
    let bytes = [UInt8](buffer)
    guard bytes.count >= 2 else { return nil }
    let opcode = bytes[0] & 0x0f
    let masked = (bytes[1] & 0x80) != 0
    var len = Int(bytes[1] & 0x7f)
    var offset = 2
    if len == 126 {
        guard bytes.count >= 4 else { return nil }
        len = Int(bytes[2]) << 8 | Int(bytes[3])
        offset = 4
    } else if len == 127 {
        guard bytes.count >= 10 else { return nil }
        len = 0
        for i in 2..<10 { len = len << 8 | Int(bytes[i]) }
        offset = 10
    }
    var maskKey: [UInt8]? = nil
    if masked {
        guard bytes.count >= offset + 4 else { return nil }
        maskKey = Array(bytes[offset..<(offset + 4)])
        offset += 4
    }
    guard bytes.count >= offset + len else { return nil }
    var payload = Array(bytes[offset..<(offset + len)])
    if let key = maskKey {
        for i in 0..<payload.count { payload[i] ^= key[i % 4] }
    }
    return WSFrame(opcode: opcode, payload: Data(payload), consumed: offset + len)
}

/// 构造客户端帧（RFC6455：客户端帧必须 mask）
private func wsFrame(opcode: UInt8, payload: Data) -> Data {
    var out = Data([0x80 | opcode])
    let maskKey: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }
    let len = payload.count
    if len < 126 {
        out.append(UInt8(0x80 | len))
    } else if len <= 0xFFFF {
        out.append(UInt8(0x80 | 126))
        out.append(UInt8((len >> 8) & 0xFF))
        out.append(UInt8(len & 0xFF))
    } else {
        out.append(UInt8(0x80 | 127))
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((len >> shift) & 0xFF))
        }
    }
    out.append(contentsOf: maskKey)
    var masked = [UInt8](payload)
    for i in 0..<masked.count { masked[i] ^= maskKey[i % 4] }
    out.append(contentsOf: masked)
    return out
}
