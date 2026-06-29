import Foundation
import Network

public final class LocalHTTPServer: @unchecked Sendable {
    private let proxy: LocalAPIProxy
    private let queue = DispatchQueue(label: "app.msr.local-http")
    private var listener: NWListener?

    public private(set) var port: UInt16

    public init(proxy: LocalAPIProxy, port: UInt16 = 47837) {
        self.proxy = proxy
        self.port = port
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: port) ?? 47837
        )
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            guard let self, let data else {
                connection.cancel()
                return
            }
            Task {
                let response = await self.response(for: data)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for data: Data) async -> Data {
        do {
            let request = try parseRequest(data)
            let handled = try await proxy.handle(
                method: request.method,
                path: request.path,
                body: request.body
            )
            return makeHTTPResponse(statusCode: handled.statusCode, contentType: handled.contentType, body: handled.body)
        } catch {
            let status: Int
            if case .notFound = error as? LocalAPIError {
                status = 404
            } else {
                status = 400
            }
            let body = #"{"error":"\#(error.localizedDescription)"}"#.data(using: .utf8) ?? Data()
            return makeHTTPResponse(statusCode: status, contentType: "application/json", body: body)
        }
    }

    private func parseRequest(_ data: Data) throws -> ParsedHTTPRequest {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else {
            throw LocalAPIError.badRequest("Invalid HTTP request.")
        }
        let header = String(raw[..<headerEnd.lowerBound])
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw LocalAPIError.badRequest("Missing HTTP request line.")
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            throw LocalAPIError.badRequest("Invalid HTTP request line.")
        }
        let bodyStart = raw.distance(from: raw.startIndex, to: headerEnd.upperBound)
        let body = data.dropFirst(bodyStart)
        return ParsedHTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            body: Data(body)
        )
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
    var body: Data
}
