import Foundation
import Network
import AVFoundation
import WhisperKit

// --- Config ---
let serverPort = 8080
let authToken: String = ProcessInfo.processInfo.environment["SPEECHTEXT_TOKEN"] ?? "speechtext-secret"

print("[Server] Starting SpeechText Server on port \(serverPort)...")

var whisperKitReady = false
var whisperKit: WhisperKit?

Task {
    do {
        let config = WhisperKitConfig(model: "tiny", verbose: false, logLevel: .none)
        whisperKit = try await WhisperKit(config)
        whisperKitReady = true
        print("[Server] WhisperKit loaded, ready to transcribe")
    } catch {
        print("[Server] Failed to load WhisperKit: \(error)")
    }
}

// --- HTTP Server ---
let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: UInt16(serverPort))!)

listener.newConnectionHandler = { connection in
    connection.start(queue: .global())
    Task {
        await handleConnection(connection)
    }
}

listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("[Server] Listening on port \(serverPort)")
    case .failed(let err):
        print("[Server] Listener failed: \(err)")
    default:
        break
    }
}
listener.start(queue: .main)

func handleConnection(_ connection: NWConnection) async {
    // Read all incoming data
    let data = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2_000_000) { data, _, _, error in
            cont.resume(returning: data)
        }
    }

    guard let data = data,
          let raw = String(data: data, encoding: .utf8) else {
        connection.cancel()
        return
    }

    let request = parseHTTP(raw)
    let response = await handleRequest(request)
    let responseData = Data(response.utf8)

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
            cont.resume()
        })
    }
}

struct ParsedRequest {
    let path: String
    let queryParams: [String: String]
    let body: String
}

func parseHTTP(_ raw: String) -> ParsedRequest {
    let sections = raw.split(separator: "\r\n\r\n", maxSplits: 1)
    let headers = String(sections[0])
    let body = sections.count > 1 ? String(sections[1]) : ""

    let lines = headers.split(separator: "\r\n")
    let firstLine = String(lines.first ?? "")
    let parts = firstLine.split(separator: " ")
    let fullPath = parts.count > 1 ? String(parts[1]) : "/"

    var path = fullPath
    var queryParams: [String: String] = [:]
    if let qMark = fullPath.firstIndex(of: "?") {
        path = String(fullPath[..<qMark])
        let query = String(fullPath[fullPath.index(after: qMark)...])
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                queryParams[String(kv[0])] = String(kv[1])
            }
        }
    }

    return ParsedRequest(path: path, queryParams: queryParams, body: body)
}

func handleRequest(_ req: ParsedRequest) async -> String {
    let body = jsonBody(status: 200, text: nil, error: nil)

    guard let token = req.queryParams["token"], token == authToken else {
        return httpResponse(status: 401, body: jsonBody(status: 401, error: "invalid token"))
    }

    guard whisperKitReady, let wk = whisperKit else {
        return httpResponse(status: 503, body: jsonBody(status: 503, error: "model not ready"))
    }

    guard let wavData = Data(base64Encoded: req.body.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return httpResponse(status: 400, body: jsonBody(status: 400, error: "invalid base64 audio"))
    }

    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("srv_\(UUID().uuidString).wav")
    do {
        try wavData.write(to: tempURL)
        let result = try await wk.transcribe(audioPath: tempURL.path, callback: nil)
        try? FileManager.default.removeItem(at: tempURL)
        let text = result.first?.text ?? ""
        print("[Server] Transcribed: \(text.prefix(80))")
        return httpResponse(status: 200, body: jsonBody(status: 200, text: text))
    } catch {
        try? FileManager.default.removeItem(at: tempURL)
        return httpResponse(status: 500, body: jsonBody(status: 500, error: "transcription failed"))
    }
}

func httpResponse(status: Int, body: String) -> String {
    "HTTP/1.1 \(status == 200 ? "200 OK" : "\(status) Error")\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
}

func jsonBody(status: Int, text: String? = nil, error: String? = nil) -> String {
    if let text = text {
        return #"{"text":"\#(text.escapedJSON())"}"#
    } else {
        return #"{"error":"\#(error?.escapedJSON() ?? "unknown")"}"#
    }
}

extension String {
    func escapedJSON() -> String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}

// Keep the process alive
RunLoop.current.run()
