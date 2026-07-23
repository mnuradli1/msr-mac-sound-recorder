import Foundation
import Network

public final class LocalHTTPServer: @unchecked Sendable {
    private let proxy: LocalAPIProxy
    private let queue = DispatchQueue(label: "app.msr.local-http")
    private var listener: NWListener?

    public private(set) var port: UInt16
    public let bearerToken: String

    public init(proxy: LocalAPIProxy, port: UInt16 = 47837, bearerToken: String? = nil) {
        self.proxy = proxy
        self.port = port
        self.bearerToken = bearerToken ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? 47837
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
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
            guard accumulated.count <= 1_048_576 else {
                Task { await self.finish(connection: connection, requestData: Data()) }
                return
            }
            if let expected = self.expectedRequestByteCount(accumulated), accumulated.count >= expected {
                Task { await self.finish(connection: connection, requestData: accumulated) }
            } else if isComplete || error != nil {
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

    private func expectedRequestByteCount(_ data: Data) -> Int? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        if header.range(of: "transfer-encoding: chunked", options: .caseInsensitive) != nil {
            return data.range(of: Data("\r\n0\r\n\r\n".utf8), options: .backwards) == nil ? nil : data.count
        }
        let contentLength = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        return headerRange.upperBound + contentLength
    }

    private func response(for data: Data) async -> Data {
        do {
            let request = try parseRequest(data)
            if request.path != "/health" {
                guard request.headers["authorization"] == "Bearer \(bearerToken)" else {
                    throw LocalAPIError.unauthorized
                }
            }
            let handled = try await proxy.handle(
                method: request.method,
                path: request.path,
                body: request.body
            )
            return makeHTTPResponse(statusCode: handled.statusCode, contentType: handled.contentType, body: handled.body)
        } catch {
            let status: Int
            switch error as? LocalAPIError {
            case .notFound: status = 404
            case .unauthorized: status = 401
            case .forbidden: status = 403
            default: status = 400
            }
            let body = #"{"error":"\#(error.localizedDescription)"}"#.data(using: .utf8) ?? Data()
            return makeHTTPResponse(statusCode: status, contentType: "application/json", body: body)
        }
    }

    private func parseRequest(_ data: Data) throws -> ParsedHTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let header = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw LocalAPIError.badRequest("Invalid HTTP request.")
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw LocalAPIError.badRequest("Missing HTTP request line.")
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            throw LocalAPIError.badRequest("Invalid HTTP request line.")
        }
        let headers = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line -> (String, String)? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return (name, value)
        })
        let rawBody = Data(data[headerRange.upperBound...])
        let body = if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            try decodeChunkedBody(rawBody)
        } else {
            Data(rawBody.prefix(Int(headers["content-length"] ?? "") ?? rawBody.count))
        }
        return ParsedHTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body
        )
    }

    private func decodeChunkedBody(_ data: Data) throws -> Data {
        var cursor = data.startIndex
        var decoded = Data()
        let lineBreak = Data("\r\n".utf8)
        while cursor < data.endIndex {
            guard let sizeRange = data[cursor...].range(of: lineBreak),
                  let sizeText = String(data: data[cursor..<sizeRange.lowerBound], encoding: .utf8),
                  let size = Int(sizeText.split(separator: ";", maxSplits: 1)[0], radix: 16) else {
                throw LocalAPIError.badRequest("Invalid chunked HTTP body.")
            }
            cursor = sizeRange.upperBound
            if size == 0 { return decoded }
            guard data.distance(from: cursor, to: data.endIndex) >= size + lineBreak.count else {
                throw LocalAPIError.badRequest("Incomplete chunked HTTP body.")
            }
            let end = data.index(cursor, offsetBy: size)
            decoded.append(contentsOf: data[cursor..<end])
            cursor = data.index(end, offsetBy: lineBreak.count)
        }
        throw LocalAPIError.badRequest("Incomplete chunked HTTP body.")
    }

    private func makeHTTPResponse(statusCode: Int, contentType: String, body: Data) -> Data {
        let reason = statusCode == 200 ? "OK" : "Error"
        var response = Data()
        response.append(Data("HTTP/1.1 \(statusCode) \(reason)\r\n".utf8))
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        return response
    }
}

private struct ParsedHTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}
