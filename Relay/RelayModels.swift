import Foundation

enum BackendId: String, Codable, CaseIterable, Equatable, Hashable {
    case claude, codex, gemini, openrouter
}

extension BackendId {
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        }
    }
}

struct SessionCreate: Codable, Equatable {
    let backend: BackendId
    // Optional since 2026-09-22 — omit/nil and relay-api generates a real
    // name via a quick free-model call instead of requiring one to be
    // typed every time.
    let name: String?
    let cwd: String?
    let addDirs: [String]
    let model: String?
    let effort: String?  // low|medium|high|xhigh|max

    enum CodingKeys: String, CodingKey {
        case backend, name, cwd, model, effort
        case addDirs = "add_dirs"
    }

    init(
        backend: BackendId,
        name: String? = nil,
        cwd: String? = nil,
        addDirs: [String] = [],
        model: String? = nil,
        effort: String? = nil
    ) {
        self.backend = backend
        self.name = name
        self.cwd = cwd
        self.addDirs = addDirs
        self.model = model
        self.effort = effort
    }
}

struct MessageCreate: Codable, Equatable {
    let text: String
    let filePaths: [String]

    enum CodingKeys: String, CodingKey {
        case text
        case filePaths = "file_paths"
    }

    init(text: String, filePaths: [String] = []) {
        self.text = text
        self.filePaths = filePaths
    }
}

struct ModelSwitch: Codable, Equatable {
    let model: String?
    let effort: String?

    init(model: String? = nil, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }
}

struct DowngradeRequest: Codable, Equatable {
    let model: String?

    init(model: String? = nil) {
        self.model = model
    }
}

struct ToolCall: Codable, Identifiable, Equatable {
    var id: String { name + summary }
    let name: String
    let summary: String
    let output: String?
}

/// One piece of a turn IN THE ORDER IT ACTUALLY HAPPENED — text or a tool
/// call — so the chat view can render the real back-and-forth instead of
/// "all tools" + "the final text" as two disconnected blobs. See
/// project_relay_ios_app.md's 2026-09-22 entry for why this replaced the
/// flat tool_calls-only view.
struct TurnSegment: Codable, Identifiable, Equatable {
    var id: String { type + (text ?? "") + (name ?? "") + (summary ?? "") }
    let type: String  // "text" | "tool"
    let text: String?
    let name: String?
    let summary: String?
    let output: String?
}

struct Turn: Codable, Identifiable, Equatable {
    var id: String { (timestamp ?? "") + text.prefix(20) }  // synthetic, turns have no real id
    let role: String  // "user" | "assistant" | "error"
    let text: String
    let timestamp: String?
    let costUsd: Double?
    let isError: Bool
    let toolCalls: [ToolCall]
    let segments: [TurnSegment]

    enum CodingKeys: String, CodingKey {
        case role, text, timestamp, segments
        case costUsd = "cost_usd"
        case isError = "is_error"
        case toolCalls = "tool_calls"
    }

    init(
        role: String,
        text: String,
        timestamp: String? = nil,
        costUsd: Double? = nil,
        isError: Bool = false,
        toolCalls: [ToolCall] = [],
        segments: [TurnSegment] = []
    ) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.costUsd = costUsd
        self.isError = isError
        self.toolCalls = toolCalls
        self.segments = segments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? []
        segments = try c.decodeIfPresent([TurnSegment].self, forKey: .segments) ?? []
    }
}

struct SessionSummary: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let displayName: String?
    let backend: BackendId          // CURRENTLY ACTIVE backend
    let originalBackend: BackendId
    let lockedToFree: Bool
    let status: String              // "not_running" | "idle" | "busy" | "error"
    let pid: Int?
    let cwd: String?
    let model: String?
    let effort: String?
    let createdAt: String?
    let lastActivityAt: String?

    enum CodingKeys: String, CodingKey {
        case name, backend, status, pid, cwd, model, effort
        case displayName = "display_name"
        case originalBackend = "original_backend"
        case lockedToFree = "locked_to_free"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
    }

    init(
        name: String,
        displayName: String? = nil,
        backend: BackendId,
        originalBackend: BackendId,
        lockedToFree: Bool,
        status: String,
        pid: Int? = nil,
        cwd: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        createdAt: String? = nil,
        lastActivityAt: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.backend = backend
        self.originalBackend = originalBackend
        self.lockedToFree = lockedToFree
        self.status = status
        self.pid = pid
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
    }
}

struct SessionDetail: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let displayName: String?
    let backend: BackendId          // CURRENTLY ACTIVE backend
    let originalBackend: BackendId
    let lockedToFree: Bool
    let status: String              // "not_running" | "idle" | "busy" | "error"
    let pid: Int?
    let cwd: String?
    let model: String?
    let effort: String?
    let createdAt: String?
    let lastActivityAt: String?
    let turns: [Turn]
    let transcriptMode: String      // "structured" | "raw_snapshot"
    let queuedMessages: [QueuedMessage]

    enum CodingKeys: String, CodingKey {
        case name, backend, status, pid, cwd, model, effort
        case displayName = "display_name"
        case originalBackend = "original_backend"
        case lockedToFree = "locked_to_free"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
        case turns
        case transcriptMode = "transcript_mode"
        case queuedMessages = "queued_messages"
    }

    var summary: SessionSummary {
        SessionSummary(
            name: name,
            displayName: displayName,
            backend: backend,
            originalBackend: originalBackend,
            lockedToFree: lockedToFree,
            status: status,
            pid: pid,
            cwd: cwd,
            model: model,
            effort: effort,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt
        )
    }

    init(
        name: String,
        displayName: String? = nil,
        backend: BackendId,
        originalBackend: BackendId,
        lockedToFree: Bool,
        status: String,
        pid: Int? = nil,
        cwd: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        createdAt: String? = nil,
        lastActivityAt: String? = nil,
        turns: [Turn] = [],
        transcriptMode: String = "structured",
        queuedMessages: [QueuedMessage] = []
    ) {
        self.name = name
        self.displayName = displayName
        self.backend = backend
        self.originalBackend = originalBackend
        self.lockedToFree = lockedToFree
        self.status = status
        self.pid = pid
        self.cwd = cwd
        self.model = model
        self.effort = effort
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.turns = turns
        self.transcriptMode = transcriptMode
        self.queuedMessages = queuedMessages
    }
}

struct QueuedMessage: Codable, Identifiable, Equatable {
    let id: Int
    let text: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, text
        case createdAt = "created_at"
    }
}

struct ModelOption: Codable, Identifiable, Equatable, Hashable {
    var id: String { self.idValue }
    let idValue: String
    let label: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case idValue = "id"
        case label
        case isDefault = "is_default"
    }

    init(id: String, label: String, isDefault: Bool = false) {
        self.idValue = id
        self.label = label
        self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idValue = try c.decode(String.self, forKey: .idValue)
        label = try c.decode(String.self, forKey: .label)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

struct BackendDescriptor: Codable, Identifiable, Equatable, Hashable {
    var id: BackendId { idValue }
    let idValue: BackendId
    let label: String

    enum CodingKeys: String, CodingKey {
        case idValue = "id"
        case label
    }

    init(id: BackendId, label: String) {
        self.idValue = id
        self.label = label
    }
}

struct UsageInfo: Codable, Equatable {
    let text: String
    let fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case text
        case fetchedAt = "fetched_at"
    }

    init(text: String, fetchedAt: String) {
        self.text = text
        self.fetchedAt = fetchedAt
    }
}

struct StatusResponse: Codable, Equatable {
    let status: String

    init(status: String) {
        self.status = status
    }
}

struct FileUploadResponse: Codable, Equatable {
    let path: String
    let warning: String?

    init(path: String, warning: String? = nil) {
        self.path = path
        self.warning = warning
    }
}
