import Foundation
import AVFoundation

struct RemoteTranscriberService {
    let serverURL: URL
    let authToken: String

    init(serverURL: URL, authToken: String) {
        self.serverURL = serverURL
        self.authToken = authToken
    }

    func transcribeFile(path: String) async -> String? {
        guard let wavData = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return await transcribeWAV(wavData)
    }

    func transcribeWAV(_ data: Data) async -> String? {
        guard var urlComponents = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        urlComponents.queryItems = [URLQueryItem(name: "token", value: authToken)]

        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        // Send as base64-wrapped WAV for simplicity
        let body = data.base64EncodedString()
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 30

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["text"] as? String,
                  !text.isEmpty else { return nil }
            return text
        } catch {
            print("[RemoteTranscriberService] Request failed: \(error)")
            return nil
        }
    }
}
