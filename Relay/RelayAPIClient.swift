import Foundation

enum RelayAPIError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case encodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode, let message):
            return "HTTP \(statusCode): \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .encodingError(let error):
            return "Failed to encode request: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

typealias APIError = RelayAPIError

final class RelayAPIClient {
    static let shared = RelayAPIClient()

    let baseURL: URL
    let bearerToken: String
    private let session: URLSession

    // Note: Models define explicit snake_case CodingKeys, so do NOT set
    // keyDecodingStrategy = .convertFromSnakeCase (that would double-convert and break decoding).
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        baseURL: URL = URL(string: "https://relay.jdries.nl")!,
        bearerToken: String = "2507a9a5675a13ed9fc42461adcb817a225a72b3781ea0f51e2e203454fd82b2",
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.session = session

        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Internal Networking Helpers

    private func makeURL(path: String, queryItems: [URLQueryItem]? = nil) throws -> URL {
        let baseString = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        let pathString = path.hasPrefix("/") ? path : "/" + path
        let fullString = baseString + pathString

        guard var components = URLComponents(string: fullString) else {
            throw RelayAPIError.invalidURL(fullString)
        }

        if let queryItems = queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw RelayAPIError.invalidURL(fullString)
        }

        return url
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeJSONRequest<T: Encodable>(url: URL, method: String, body: T) throws -> URLRequest {
        var request = makeRequest(url: url, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw RelayAPIError.encodingError(error)
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performRaw(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RelayAPIError.decodingError(error)
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RelayAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorMessage: String?

            if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let detail = jsonObject["detail"] as? String {
                    errorMessage = detail
                } else if let detail = jsonObject["detail"] {
                    if let detailData = try? JSONSerialization.data(withJSONObject: detail),
                       let detailString = String(data: detailData, encoding: .utf8) {
                        errorMessage = detailString
                    }
                } else if let message = jsonObject["message"] as? String {
                    errorMessage = message
                } else if let error = jsonObject["error"] as? String {
                    errorMessage = error
                }
            }

            if errorMessage == nil, let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    errorMessage = trimmed
                }
            }

            let resolvedMessage = errorMessage ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw RelayAPIError.httpError(statusCode: httpResponse.statusCode, message: resolvedMessage)
        }

        return data
    }

    // MARK: - API Endpoints

    /// GET /api/backends -> [BackendDescriptor]
    func getBackends() async throws -> [BackendDescriptor] {
        let url = try makeURL(path: "/api/backends")
        let request = makeRequest(url: url, method: "GET")
        return try await perform(request)
    }

    func fetchBackends() async throws -> [BackendDescriptor] {
        try await getBackends()
    }

    /// GET /api/models?backend=<id> -> [ModelOption]
    func getModels(backend: BackendId) async throws -> [ModelOption] {
        let queryItem = URLQueryItem(name: "backend", value: backend.rawValue)
        let url = try makeURL(path: "/api/models", queryItems: [queryItem])
        let request = makeRequest(url: url, method: "GET")
        return try await perform(request)
    }

    func getModels(backend: String) async throws -> [ModelOption] {
        let queryItem = URLQueryItem(name: "backend", value: backend)
        let url = try makeURL(path: "/api/models", queryItems: [queryItem])
        let request = makeRequest(url: url, method: "GET")
        return try await perform(request)
    }

    func fetchModels(backend: BackendId) async throws -> [ModelOption] {
        try await getModels(backend: backend)
    }

    func fetchModels(backend: String) async throws -> [ModelOption] {
        try await getModels(backend: backend)
    }

    /// GET /api/usage -> UsageInfo
    func getUsage() async throws -> UsageInfo {
        let url = try makeURL(path: "/api/usage")
        let request = makeRequest(url: url, method: "GET")
        return try await perform(request)
    }

    func fetchUsage() async throws -> UsageInfo {
        try await getUsage()
    }

    /// GET /api/sessions -> [SessionSummary]
    func getSessions() async throws -> [SessionSummary] {
        let url = try makeURL(path: "/api/sessions")
        let request = makeRequest(url: url, method: "GET")
        return try await perform(request)
    }

    func fetchSessions() async throws -> [SessionSummary] {
        try await getSessions()
    }

    /// POST /api/sessions (body SessionCreate) -> SessionSummary
    func createSession(_ sessionCreate: SessionCreate) async throws -> SessionSummary {
        let url = try makeURL(path: "/api/sessions")
        let request = try makeJSONRequest(url: url, method: "POST", body: sessionCreate)
        return try await perform(request)
    }

    func createSession(
        backend: BackendId,
        name: String,
        cwd: String? = nil,
        addDirs: [String] = [],
        model: String? = nil,
        effort: String? = nil
    ) async throws -> SessionSummary {
        let create = SessionCreate(
            backend: backend,
            name: name,
            cwd: cwd,
            addDirs: addDirs,
            model: model,
            effort: effort
        )
        return try await createSession(create)
    }

    /// GET /api/sessions/{name}?lines=500 -> SessionDetail
    func getSessionDetail(name: String, lines: Int = 500) async throws -> SessionDetail {
        let escapedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        let queryItem = URLQueryItem(name: "lines", value: String(lines))
        let url = try makeURL(path: "/api/sessions/\(escapedName)", queryItems: [queryItem])
        let request = makeRequest(url: url, method: "GET")
        return try await perform(request)
    }

    func fetchSessionDetail(name: String, lines: Int = 500) async throws -> SessionDetail {
        try await getSessionDetail(name: name, lines: lines)
    }

    func getSessionDetail(sessionName: String, lines: Int = 500) async throws -> SessionDetail {
        try await getSessionDetail(name: sessionName, lines: lines)
    }

    /// POST /api/sessions/{name}/messages (body MessageCreate) -> {"status":"sent"}
    @discardableResult
    func sendMessage(sessionName: String, message: MessageCreate) async throws -> StatusResponse {
        let escapedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = try makeURL(path: "/api/sessions/\(escapedName)/messages")
        let request = try makeJSONRequest(url: url, method: "POST", body: message)
        return try await perform(request)
    }

    @discardableResult
    func sendMessage(name: String, message: MessageCreate) async throws -> StatusResponse {
        try await sendMessage(sessionName: name, message: message)
    }

    @discardableResult
    func sendMessage(sessionName: String, text: String, filePaths: [String] = []) async throws -> StatusResponse {
        let message = MessageCreate(text: text, filePaths: filePaths)
        return try await sendMessage(sessionName: sessionName, message: message)
    }

    /// POST /api/sessions/{name}/stop -> {"status":"stopped"}
    @discardableResult
    func stopSession(sessionName: String) async throws -> StatusResponse {
        let escapedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = try makeURL(path: "/api/sessions/\(escapedName)/stop")
        let request = makeRequest(url: url, method: "POST")
        return try await perform(request)
    }

    @discardableResult
    func stopSession(name: String) async throws -> StatusResponse {
        try await stopSession(sessionName: name)
    }

    /// POST /api/sessions/{name}/model (body ModelSwitch) -> SessionSummary
    func switchModel(sessionName: String, modelSwitch: ModelSwitch) async throws -> SessionSummary {
        let escapedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = try makeURL(path: "/api/sessions/\(escapedName)/model")
        let request = try makeJSONRequest(url: url, method: "POST", body: modelSwitch)
        return try await perform(request)
    }

    func switchModel(name: String, modelSwitch: ModelSwitch) async throws -> SessionSummary {
        try await switchModel(sessionName: name, modelSwitch: modelSwitch)
    }

    func switchModel(sessionName: String, model: String?, effort: String? = nil) async throws -> SessionSummary {
        let modelSwitch = ModelSwitch(model: model, effort: effort)
        return try await switchModel(sessionName: sessionName, modelSwitch: modelSwitch)
    }

    /// POST /api/sessions/{name}/downgrade (body DowngradeRequest) -> SessionSummary
    func downgradeSession(sessionName: String, request: DowngradeRequest) async throws -> SessionSummary {
        let escapedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = try makeURL(path: "/api/sessions/\(escapedName)/downgrade")
        let request = try makeJSONRequest(url: url, method: "POST", body: request)
        return try await perform(request)
    }

    func downgradeSession(name: String, request: DowngradeRequest) async throws -> SessionSummary {
        try await downgradeSession(sessionName: name, request: request)
    }

    func downgradeSession(sessionName: String, model: String? = nil) async throws -> SessionSummary {
        let request = DowngradeRequest(model: model)
        return try await downgradeSession(sessionName: sessionName, request: request)
    }

    /// POST /api/sessions/{name}/files (multipart file upload) -> FileUploadResponse
    @discardableResult
    func uploadFile(
        sessionName: String,
        fileData: Data,
        fileName: String,
        mimeType: String? = nil
    ) async throws -> FileUploadResponse {
        let escapedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        let url = try makeURL(path: "/api/sessions/\(escapedName)/files")
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        guard let boundaryPrefix = "--\(boundary)\r\n".data(using: .utf8),
              let disposition = "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8),
              let contentType = "Content-Type: \(mimeType ?? "application/octet-stream")\r\n\r\n".data(using: .utf8),
              let lineBreak = "\r\n".data(using: .utf8),
              let boundarySuffix = "--\(boundary)--\r\n".data(using: .utf8) else {
            throw RelayAPIError.encodingError(
                NSError(
                    domain: "RelayAPIClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create multipart form data"]
                )
            )
        }

        body.append(boundaryPrefix)
        body.append(disposition)
        body.append(contentType)
        body.append(fileData)
        body.append(lineBreak)
        body.append(boundarySuffix)

        var request = makeRequest(url: url, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        return try await perform(request)
    }

    @discardableResult
    func uploadFile(
        name: String,
        fileData: Data,
        fileName: String,
        mimeType: String? = nil
    ) async throws -> FileUploadResponse {
        try await uploadFile(
            sessionName: name,
            fileData: fileData,
            fileName: fileName,
            mimeType: mimeType
        )
    }

    @discardableResult
    func uploadFile(
        sessionName: String,
        fileURL: URL,
        mimeType: String? = nil
    ) async throws -> FileUploadResponse {
        let data = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent
        return try await uploadFile(
            sessionName: sessionName,
            fileData: data,
            fileName: fileName,
            mimeType: mimeType
        )
    }
}
