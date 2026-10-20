import Foundation
import Network

public enum LocalHTTPServerError: Error, LocalizedError, Equatable {
    case startFailed(String)
    case startTimedOut
    case listenerCancelled

    public var errorDescription: String? {
        switch self {
        case let .startFailed(message):
            return "Local API could not listen on 127.0.0.1: \(message)"
        case .startTimedOut:
            return "Local API listener did not become ready in time."
        case .listenerCancelled:
            return "Local API listener was cancelled while starting."
        }
    }
}

public final class LocalHTTPServer: @unchecked Sendable {
    private static let startTimeout: TimeInterval = 2

    private let proxy: LocalAPIProxy
    private let queue = DispatchQueue(label: "app.msr.local-http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var listening = false
    private var boundPort: UInt16

    /// The listening port. When initialized with port 0 this becomes the OS-assigned port once `start()` returns.
    public var port: UInt16 { lock.withLock { boundPort } }
    public let bearerToken: String
    /// True while the listener is in the `.ready` state; flips to false if it later fails or is stopped.
    public var isListening: Bool { lock.withLock { listening } }

    public init(proxy: LocalAPIProxy, port: UInt16 = 47837, bearerToken: String? = nil) {
        self.proxy = proxy
        self.boundPort = port
        self.bearerToken = bearerToken ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Binds 127.0.0.1 and blocks for up to ~2 s until the listener is ready.
    /// Throws `LocalHTTPServerError` when the port cannot be bound or the listener never becomes ready.
    public func start() throws {
        let requestedPort: UInt16? = lock.withLock { self.listener == nil ? boundPort : nil }
        guard let requestedPort else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LocalHTTPServerError.startFailed(error.localizedDescription)
        }
        let startup = ListenerStartup()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                self?.listenerBecameReady(port: listener?.port?.rawValue)
                startup.finish(.ready)
            case let .waiting(error):
                startup.noteWaiting(error)
            case let .failed(error):
                self?.listenerStopped(listener)
                startup.finish(.failed(error))
                listener?.cancel()
            case .cancelled:
                self?.listenerStopped(listener)
                startup.finish(.cancelled)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        lock.withLock { self.listener = listener }
        listener.start(queue: queue)

        switch startup.wait(timeout: Self.startTimeout) {
        case .ready:
            return
        case let .failed(error):
            stop(listener)
            throw LocalHTTPServerError.startFailed(error.localizedDescription)
        case .cancelled:
            stop(listener)
            throw LocalHTTPServerError.listenerCancelled
        case let .timedOut(waitingError):
            stop(listener)
            if let waitingError {
                throw LocalHTTPServerError.startFailed(waitingError.localizedDescription)
            }
            throw LocalHTTPServerError.startTimedOut
        }
    }

    public func stop() {
        let current: NWListener? = lock.withLock {
            let current = listener
            listener = nil
            listening = false
            return current
        }
        current?.cancel()
    }

    private func stop(_ candidate: NWListener) {
        listenerStopped(candidate)
        candidate.cancel()
    }

    private func listenerBecameReady(port: UInt16?) {
        lock.withLock {
            listening = true
            if let port, port != 0 { boundPort = port }
        }
    }

    private func listenerStopped(_ candidate: NWListener?) {
        lock.withLock {
            guard let candidate, listener === candidate else { return }
            listener = nil
            listening = false
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection: connection, buffer: Data())
    }

    private func receiveRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if HTTPRequestParser.isReadyToParse(accumulated) || isComplete || error != nil {
                Task { await self.finish(connection: connection, requestData: accumulated) }
            } else {
                self.receiveRequest(connection: connection, buffer: accumulated)
            }
        }
    }

    private func finish(connection: NWConnection, requestData: Data) async {
        let response = await response(for: requestData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    func response(for data: Data) async -> Data {
        do {
            let request = try HTTPRequestParser.parse(data)
            let path = request.routePath
            if path != "/health" {
                guard Self.isAuthorized(authorizationHeader: request.headers["authorization"], token: bearerToken) else {
                    throw LocalAPIError.unauthorized
                }
            }
            let handled = try await proxy.handle(method: request.method, path: path, body: request.body)
            return HTTPResponseWriter.response(statusCode: handled.statusCode, contentType: handled.contentType, body: handled.body)
        } catch {
            let status = Self.statusCode(for: error)
            return HTTPResponseWriter.errorResponse(statusCode: status, message: Self.errorMessage(for: error, statusCode: status))
        }
    }

    static func statusCode(for error: Error) -> Int {
        switch error {
        case let error as LocalAPIError:
            switch error {
            case .notFound: return 404
            case .unauthorized: return 401
            case .forbidden: return 403
            case .badRequest: return 400
            }
        case let error as HTTPRequestError:
            switch error {
            case .malformed: return 400
            case .payloadTooLarge: return 413
            }
        case is DecodingError:
            return 400
        case is EncodingError:
            return 500
        case ProviderError.audioFileMissing:
            return 400
        default:
            // Anything else came from the AI service behind the proxy (provider rejection, network failure).
            return 502
        }
    }

    private static func errorMessage(for error: Error, statusCode: Int) -> String {
        switch error {
        case is DecodingError:
            return "Request body is not valid JSON for this endpoint."
        case is EncodingError:
            return "Response could not be encoded."
        default:
            return error.localizedDescription
        }
    }

    /// Accepts `Authorization: Bearer <token>` (scheme is case-insensitive) using a constant-time comparison.
    static func isAuthorized(authorizationHeader: String?, token: String) -> Bool {
        guard let header = authorizationHeader?.trimmingCharacters(in: .whitespaces),
              header.count > 7,
              header.prefix(7).lowercased() == "bearer " else { return false }
        let credentials = header.dropFirst(7).trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(credentials, token)
    }

    /// Compares every byte regardless of where the first mismatch occurs, so timing reveals only the lengths.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt64(truncatingIfNeeded: left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= UInt64(a ^ b)
        }
        return difference == 0
    }
}

enum HTTPRequestError: Error, LocalizedError, Equatable {
    case malformed(String)
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case let .malformed(message): return message
        case .payloadTooLarge: return "Request exceeds the 1 MB limit."
        }
    }
}

struct ParsedHTTPRequest: Equatable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// The request target without its query string, used for routing.
    var routePath: String {
        path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
    }
}

/// Parses raw HTTP/1.1 request bytes. Never traps on hostile input: malformed requests throw `HTTPRequestError`.
enum HTTPRequestParser {
    static let maximumRequestBytes = 1_048_576
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let lineBreak = Data("\r\n".utf8)

    enum ChunkedBody: Equatable {
        case complete(Data)
        case incomplete
    }

    /// True once `parse` can produce a final answer: the request is complete, malformed, or over the size limit.
    static func isReadyToParse(_ data: Data) -> Bool {
        if data.count > maximumRequestBytes { return true }
        guard let headerRange = data.range(of: headerTerminator) else { return false }
        guard let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return true }
        let headers = parseHeaders(header.components(separatedBy: "\r\n").dropFirst())
        let rawBody = data[headerRange.upperBound...]
        if isChunked(headers) {
            do {
                return try decodeChunkedBody(Data(rawBody)) != .incomplete
            } catch {
                return true
            }
        }
        guard let lengthHeader = headers["content-length"] else { return true }
        guard let length = contentLength(lengthHeader), length <= maximumRequestBytes else { return true }
        return rawBody.count >= length
    }

    static func parse(_ data: Data) throws -> ParsedHTTPRequest {
        guard data.count <= maximumRequestBytes else { throw HTTPRequestError.payloadTooLarge }
        guard let headerRange = data.range(of: headerTerminator),
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw HTTPRequestError.malformed("Invalid HTTP request.")
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            throw HTTPRequestError.malformed("Missing HTTP request line.")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw HTTPRequestError.malformed("Invalid HTTP request line.")
        }
        let headers = parseHeaders(lines.dropFirst())
        let rawBody = Data(data[headerRange.upperBound...])
        let body: Data
        if isChunked(headers) {
            guard case let .complete(decoded) = try decodeChunkedBody(rawBody) else {
                throw HTTPRequestError.malformed("Incomplete chunked HTTP body.")
            }
            body = decoded
        } else if let lengthHeader = headers["content-length"] {
            guard let length = contentLength(lengthHeader) else {
                throw HTTPRequestError.malformed("Invalid Content-Length header.")
            }
            guard length <= maximumRequestBytes else { throw HTTPRequestError.payloadTooLarge }
            guard rawBody.count >= length else {
                throw HTTPRequestError.malformed("Incomplete HTTP body.")
            }
            body = Data(rawBody.prefix(length))
        } else {
            body = rawBody
        }
        return ParsedHTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body
        )
    }

    /// Lower-cased header names; a repeated header keeps its last value instead of trapping.
    static func parseHeaders<Lines: Sequence>(_ lines: Lines) -> [String: String] where Lines.Element == String {
        let pairs = lines.compactMap { line -> (String, String)? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty else { return nil }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, value)
        }
        return Dictionary(pairs, uniquingKeysWith: { _, last in last })
    }

    /// Non-negative decimal Content-Length, or nil when the value is negative, signed, or not a number.
    static func contentLength(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(trimmed)
    }

    private static func isChunked(_ headers: [String: String]) -> Bool {
        headers["transfer-encoding"]?.lowercased().contains("chunked") == true
    }

    static func decodeChunkedBody(_ data: Data) throws -> ChunkedBody {
        var cursor = data.startIndex
        var decoded = Data()
        while true {
            guard let sizeLineRange = data[cursor...].range(of: lineBreak) else {
                if data.distance(from: cursor, to: data.endIndex) > 1_024 {
                    throw HTTPRequestError.malformed("Invalid chunk size line.")
                }
                return .incomplete
            }
            guard let sizeLine = String(data: data[cursor..<sizeLineRange.lowerBound], encoding: .utf8) else {
                throw HTTPRequestError.malformed("Invalid chunk size line.")
            }
            let sizeField = sizeLine
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeField.isEmpty, sizeField.count <= 16, sizeField.allSatisfy(\.isHexDigit),
                  let size = Int(sizeField, radix: 16) else {
                throw HTTPRequestError.malformed("Invalid chunk size.")
            }
            guard size <= maximumRequestBytes, decoded.count + size <= maximumRequestBytes else {
                throw HTTPRequestError.payloadTooLarge
            }
            cursor = sizeLineRange.upperBound
            if size == 0 {
                let trailer = data[cursor...]
                if trailer.starts(with: lineBreak) || trailer.range(of: headerTerminator) != nil {
                    return .complete(decoded)
                }
                return .incomplete
            }
            guard data.distance(from: cursor, to: data.endIndex) >= size + lineBreak.count else {
                return .incomplete
            }
            let end = data.index(cursor, offsetBy: size)
            let next = data.index(end, offsetBy: lineBreak.count)
            guard data[end..<next].elementsEqual(lineBreak) else {
                throw HTTPRequestError.malformed("Chunk data was not terminated by CRLF.")
            }
            decoded.append(contentsOf: data[cursor..<end])
            cursor = next
        }
    }
}

enum HTTPResponseWriter {
    private struct ErrorBody: Encodable {
        let error: String
    }

    static func errorResponse(statusCode: Int, message: String) -> Data {
        let body = (try? JSONEncoder().encode(ErrorBody(error: message))) ?? Data(#"{"error":"Internal error"}"#.utf8)
        return response(statusCode: statusCode, contentType: "application/json", body: body)
    }

    static func response(statusCode: Int, contentType: String, body: Data) -> Data {
        var response = Data()
        response.append(Data("HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))\r\n".utf8))
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        if statusCode == 401 {
            response.append(Data("WWW-Authenticate: Bearer\r\n".utf8))
        }
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        return response
    }

    static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }
}

private final class ListenerStartup: @unchecked Sendable {
    enum Outcome {
        case ready
        case failed(Error)
        case cancelled
        case timedOut(Error?)
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Outcome?
    private var waitingError: Error?

    func noteWaiting(_ error: Error) {
        lock.withLock { waitingError = error }
    }

    func finish(_ value: Outcome) {
        let isFirst = lock.withLock {
            guard outcome == nil else { return false }
            outcome = value
            return true
        }
        if isFirst { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Outcome {
        _ = semaphore.wait(timeout: .now() + timeout)
        return lock.withLock { outcome ?? .timedOut(waitingError) }
    }
}
