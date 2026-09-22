# Relay native SwiftUI rebuild — shared API contract

Jan wants Relay rebuilt as a REAL native SwiftUI app (not the current
WKWebView shell — that's being retired). The backend (`relay-api`, FastAPI,
already live at `https://relay.jdries.nl`) stays exactly as-is; only the iOS
client changes. This file is the fixed contract every file in this rebuild
must code against — don't invent different type/field names.

## Auth
Every `/api/*` call needs header `Authorization: Bearer <token>`.
Token (personal app, never published, same pattern as this app's existing
`PushNotifications.swift` — a hardcoded constant is fine, not a secret
worth protecting harder than that):
```
2507a9a5675a13ed9fc42461adcb817a225a72b3781ea0f51e2e203454fd82b2
```
Base URL: `https://relay.jdries.nl`

## Swift models (put these in `RelayModels.swift` — every other file imports/uses these exact names)

```swift
enum BackendId: String, Codable, CaseIterable {
    case claude, codex, gemini, openrouter
}

struct SessionCreate: Codable {
    let backend: BackendId
    let name: String
    let cwd: String?
    let addDirs: [String]
    let model: String?
    let effort: String?  // low|medium|high|xhigh|max
    enum CodingKeys: String, CodingKey {
        case backend, name, cwd, model, effort
        case addDirs = "add_dirs"
    }
}

struct MessageCreate: Codable {
    let text: String
    let filePaths: [String]
    enum CodingKeys: String, CodingKey {
        case text
        case filePaths = "file_paths"
    }
}

struct ModelSwitch: Codable {
    let model: String?
    let effort: String?
}

struct DowngradeRequest: Codable {
    let model: String?
}

struct Turn: Codable, Identifiable {
    var id: String { (timestamp ?? "") + text.prefix(20) }  // synthetic, turns have no real id
    let role: String  // "user" | "assistant" | "error"
    let text: String
    let timestamp: String?
    let costUsd: Double?
    let isError: Bool
    enum CodingKeys: String, CodingKey {
        case role, text, timestamp
        case costUsd = "cost_usd"
        case isError = "is_error"
    }
}

struct SessionSummary: Codable, Identifiable {
    var id: String { name }
    let name: String
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
        case originalBackend = "original_backend"
        case lockedToFree = "locked_to_free"
        case createdAt = "created_at"
        case lastActivityAt = "last_activity_at"
    }
}

struct SessionDetail: Codable {
    let summary: SessionSummary  // NOTE: server actually flattens these fields onto
                                  // the same JSON object (SessionDetail extends
                                  // SessionSummary in Python/Pydantic) -- when you
                                  // decode, decode SessionDetail's OWN CodingKeys
                                  // covering ALL of SessionSummary's fields PLUS
                                  // turns+transcriptMode, don't nest a sub-object.
    let turns: [Turn]
    let transcriptMode: String   // "structured" | "raw_snapshot"
}
// ^ Practical note: give SessionDetail the exact same flat field list as
// SessionSummary (copy all its properties directly into SessionDetail,
// don't nest), plus `turns: [Turn]` and `transcriptMode` (key "transcript_mode").
// This matches the real API response shape (a flat JSON object, not nested).

struct ModelOption: Codable, Identifiable {
    var id: String { self.idValue }
    let idValue: String
    let label: String
    enum CodingKeys: String, CodingKey { case idValue = "id", label }
}

struct BackendDescriptor: Codable, Identifiable {
    var id: BackendId { idValue }
    let idValue: BackendId
    let label: String
    enum CodingKeys: String, CodingKey { case idValue = "id", label }
}

struct UsageInfo: Codable {
    let text: String
    let fetchedAt: String
    enum CodingKeys: String, CodingKey { case text, fetchedAt = "fetched_at" }
}
```

## Endpoints (exact, already live and working — don't guess variations)

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/api/backends` | - | `[BackendDescriptor]` |
| GET | `/api/models?backend=<id>` | - | `[ModelOption]` |
| GET | `/api/usage` | - | `UsageInfo` |
| GET | `/api/sessions` | - | `[SessionSummary]` |
| POST | `/api/sessions` | `SessionCreate` | `SessionSummary` |
| GET | `/api/sessions/{name}?lines=500` | - | `SessionDetail` |
| POST | `/api/sessions/{name}/messages` | `MessageCreate` | `{"status":"sent"}` |
| POST | `/api/sessions/{name}/stop` | - | `{"status":"stopped"}` |
| POST | `/api/sessions/{name}/model` | `ModelSwitch` | `SessionSummary` |
| POST | `/api/sessions/{name}/downgrade` | `DowngradeRequest` | `SessionSummary` |
| POST | `/api/sessions/{name}/files` | multipart file upload | - |

Note: routes are `/api/sessions/{name}`, NOT `/api/sessions/{backend}/{name}` —
identity is the session `name` alone (globally unique across backends), the
backend is looked up server-side. (An older design doc said otherwise —
this table, read from the real live `main.py`, is authoritative.)

## UX reference (existing, working web frontend — port the UX, not the DOM)
`/home/jan/relay-api/web/{index.html,app.js,style.css}` — read this for the
actual interaction design (session list w/ status pills, new-session sheet,
chat screen with busy state + stop button, model-switch sheet, downgrade
sheet with a one-way warning, file/image attach). Translate to native
SwiftUI idioms (e.g. a `List`, a `.sheet()`, a `NavigationStack`) — don't
try to literally recreate the HTML layout.

## Design language
Dark theme (matches the official Claude Code Remote Control screen's look
Jan referenced originally) — hardcode dark, don't follow system light/dark.
Three backend accent colors for Claude/Codex/Gemini (pick reasonable ones,
e.g. Claude=orange, Codex=purple, Gemini=blue — consistent with the app's
existing icon in `Assets.xcassets`, which already has 3 colored dots).

## Polling
Session list: poll `GET /api/sessions` every 5s while the screen is visible.
Chat screen: poll `GET /api/sessions/{name}` every 3s while visible. Busy
state (`status == "busy"`): keep polling, disable the send button, show
a Stop button.
