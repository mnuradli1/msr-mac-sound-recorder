import Foundation

struct MultipartFormData {
    let boundary: String
    private var body = Data()

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    mutating func appendField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    mutating func appendFile(name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    mutating func finalize() -> Data {
        append("--\(boundary)--\r\n")
        return body
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}

struct MultipartFileBody {
    let boundary: String
    let url: URL

    static func neutralMediaDescriptor(for sourceURL: URL) -> (fileName: String, mimeType: String) {
        switch sourceURL.pathExtension.lowercased() {
        case "mp3": ("audio.mp3", "audio/mpeg")
        case "wav": ("audio.wav", "audio/wav")
        default: ("audio.m4a", "audio/mp4")
        }
    }

    static func create(
        fields: [(name: String, value: String)],
        fileFieldName: String,
        neutralFileName: String,
        mimeType: String,
        sourceURL: URL
    ) throws -> MultipartFileBody {
        let boundary = "Boundary-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("msr-upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: url)
        do {
            for field in fields {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n".utf8))
            }
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(neutralFileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.synchronize()
            try output.close()
            return MultipartFileBody(boundary: boundary, url: url)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
