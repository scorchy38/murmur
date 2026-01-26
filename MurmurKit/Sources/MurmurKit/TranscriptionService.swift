import Foundation

public enum TranscriptionError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response"
        case .apiError(let msg): return msg
        }
    }
}

public actor TranscriptionService {
    public static let shared = TranscriptionService()

    private let baseURL = "https://api.groq.com/openai/v1/audio/transcriptions"

    private var apiKey: String {
        // Check UserDefaults first (set via Settings), then fall back to Secrets.plist
        if let key = UserDefaults.standard.string(forKey: "groqApiKey"), !key.isEmpty {
            return key
        }
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let key = dict["GROQ_API_KEY"] as? String {
            return key
        }
        return ""
    }

    private init() {}

    public func transcribe(audioData: Data, format: String = "m4a") async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.\(format)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/\(format == "m4a" ? "mp4" : format)\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)

        // Model
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-large-v3-turbo\r\n".data(using: .utf8)!)

        // Response format
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n".data(using: .utf8)!)
        body.append("json\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw TranscriptionError.apiError(message)
            }
            throw TranscriptionError.invalidResponse
        }

        struct Response: Codable { let text: String }
        let result = try JSONDecoder().decode(Response.self, from: data)
        return result.text
    }
}
