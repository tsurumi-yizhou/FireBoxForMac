# FireBox Control Protocol

## 1. Scope

This document defines the management-plane IPC contract for FireBox. It is used by desktop management UIs and administrative tools to configure the service: managing providers, routes, connections, client authorization, and statistics.

This document is intentionally aligned to the macOS XPC implementation used by FireBox. Caller identity fields are represented by `xpcCaller`.

## 2. General Conventions

### 2.1 Request/Reply Only

All `ControlService` methods are strictly synchronous request/reply. There are no event streams.

### 2.2 Error Handling

Method failures are returned as a plain error message string. The service SHOULD pass through provider error messages directly when applicable. There are no structured error codes.

### 2.3 Authentication

Access to the `ControlService` is restricted to privileged administrative callers.

Caller identity mechanism:

- **macOS XPC**: caller metadata from `NSXPCConnection` (`pid`, `effectiveUserIdentifier`, `effectiveGroupIdentifier`, `auditSessionIdentifier`).

## 3. Enumerations

### 3.1 ProviderType

```text
OpenAI
Anthropic
Gemini
```

### 3.2 RouteStrategy

```text
Ordered
Random
```

### 3.3 ReasoningEffort

```text
Default = 0
Low     = 1
Medium  = 2
High    = 3
Max     = 4
```

### 3.4 MediaFormat

```text
Image = 0
Video = 1
Audio = 2
```

For route configuration, a bitmask representation is used for storage compatibility:

```text
ImageBit = 1
VideoBit = 2
AudioBit = 4
```

## 4. Data Types

### 4.1 ProviderInfo

```text
ProviderInfo {
  id: int32
  providerType: string
  name: string
  baseUrl: string
  enabledModelIds: string[]
  createdAt: string              // ISO 8601
  updatedAt: string              // ISO 8601
}
```

Note: API keys are never returned in responses.

### 4.2 RouteCandidateInfo

```text
RouteCandidateInfo {
  providerId: int32
  modelId: string
}
```

### 4.3 RouteInfo

```text
RouteInfo {
  id: int32
  routeId: string                // stable identifier used internally for routing
  strategy: string               // RouteStrategy value
  candidates: RouteCandidateInfo[]
  reasoning: bool
  toolCalling: bool
  inputFormatsMask: int32        // bitmask
  outputFormatsMask: int32       // bitmask
  createdAt: string              // ISO 8601
  updatedAt: string              // ISO 8601
}
```

### 4.4 ConnectionInfo

```text
ConnectionInfo {
  connectionId: int32
  xpcCaller: XPCCaller
  connectedAt: string            // ISO 8601
  requestCount: int64
  hasActiveStream: bool
}
```

### 4.5 ClientAccessRecord

```text
ClientAccessRecord {
  id: int32
  xpcCaller: XPCCaller
  requestCount: int64
  firstSeenAt: string            // ISO 8601
  lastSeenAt: string             // ISO 8601
  isAllowed: bool
  deniedUntilUtc?: string        // ISO 8601, nullable
}
```

### 4.6 XPCCaller

```text
XPCCaller {
  pid: int32
  euid: uint32
  egid: uint32
  auditSession: int32
}
```

### 4.7 StatsResponse

```text
StatsResponse {
  requestCount: int64
  promptTokens: int64
  completionTokens: int64
  totalTokens: int64
  estimatedCostUsd: float64
}
```

## 5. Methods

### 5.1 `Ping`

| | |
|---|---|
| **Request** | `{ message: string }` |
| **Response** | `{ result: string }` |
| **Notes** | Connectivity probe. Response is `"Pong: {message}"`. |

### 5.2 `Shutdown`

| | |
|---|---|
| **Request** | none |
| **Response** | none |

### 5.3 `GetVersionCode`

| | |
|---|---|
| **Request** | none |
| **Response** | `{ versionCode: int32 }` |

### 5.4 `GetDailyStats`

| | |
|---|---|
| **Request** | `{ year: int32, month: int32, day: int32 }` |
| **Response** | `StatsResponse` |

### 5.5 `GetMonthlyStats`

| | |
|---|---|
| **Request** | `{ year: int32, month: int32 }` |
| **Response** | `StatsResponse` |

### 5.6 `ListProviders`

| | |
|---|---|
| **Request** | none |
| **Response** | `{ providers: ProviderInfo[] }` |

### 5.7 `AddProvider`

| | |
|---|---|
| **Request** | `{ providerType: string, name: string, baseUrl: string, apiKey: string }` |
| **Response** | `{ providerId: int32 }` |

### 5.8 `UpdateProvider`

| | |
|---|---|
| **Request** | `{ providerId: int32, name: string, baseUrl: string, apiKey?: string, enabledModelIds: string[] }` |
| **Response** | none |
| **Notes** | If `apiKey` is omitted/null, the existing key is preserved. Implementations MUST distinguish "field not provided" from "field provided as empty". |

### 5.9 `DeleteProvider`

| | |
|---|---|
| **Request** | `{ providerId: int32 }` |
| **Response** | none |

### 5.10 `FetchProviderModels`

| | |
|---|---|
| **Request** | `{ providerId: int32 }` |
| **Response** | `{ modelIds: string[] }` |
| **Notes** | Queries the upstream provider API for available model IDs. |

### 5.11 `ListRoutes`

| | |
|---|---|
| **Request** | none |
| **Response** | `{ routes: RouteInfo[] }` |

### 5.12 `AddRoute`

| | |
|---|---|
| **Request** | `{ routeId: string, strategy: string, candidates: RouteCandidateInfo[], reasoning: bool, toolCalling: bool, inputFormatsMask: int32, outputFormatsMask: int32 }` |
| **Response** | `{ id: int32 }` |

### 5.13 `UpdateRoute`

| | |
|---|---|
| **Request** | `{ id: int32, routeId: string, strategy: string, candidates: RouteCandidateInfo[], reasoning: bool, toolCalling: bool, inputFormatsMask: int32, outputFormatsMask: int32 }` |
| **Response** | none |

### 5.14 `DeleteRoute`

| | |
|---|---|
| **Request** | `{ id: int32 }` |
| **Response** | none |

### 5.15 `ListConnections`

| | |
|---|---|
| **Request** | none |
| **Response** | `{ connections: ConnectionInfo[] }` |

### 5.16 `ListClientAccess`

| | |
|---|---|
| **Request** | none |
| **Response** | `{ records: ClientAccessRecord[] }` |

### 5.17 `UpdateClientAccessAllowed`

| | |
|---|---|
| **Request** | `{ accessId: int32, isAllowed: bool }` |
| **Response** | none |

## 6. Porting Guidance

| Platform | Mapping |
|---|---|
| macOS XPC | XPC exported object or protocol |

---
