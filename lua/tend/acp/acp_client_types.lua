--[[
  CRITICAL: Type annotations in this file are essential for Lua Language Server support.
  DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- @class tend.acp.ClientInfo
--- @field name string
--- @field version string

--- @class tend.acp.ClientCapabilities
--- @field fs tend.acp.FileSystemCapability
--- @field terminal boolean

--- @class tend.acp.InitializeParams
--- @field protocolVersion number
--- @field clientInfo tend.acp.ClientInfo
--- @field clientCapabilities tend.acp.ClientCapabilities

--- @class tend.acp.InitializeResponse
--- @field protocolVersion number
--- @field agentCapabilities tend.acp.AgentCapabilities
--- @field agentInfo tend.acp.AgentInfo
--- @field authMethods? tend.acp.AuthMethod[]

--- @class tend.acp.FileSystemCapability
--- @field readTextFile boolean
--- @field writeTextFile boolean

--- @class tend.acp.SessionCapabilities
--- @field list? boolean

--- @class tend.acp.AgentCapabilities
--- @field loadSession boolean
--- @field sessionCapabilities? tend.acp.SessionCapabilities
--- @field promptCapabilities tend.acp.PromptCapabilities

--- @class tend.acp.SessionInfo
--- @field sessionId string
--- @field cwd string
--- @field title? string
--- @field updatedAt? string
--- @field _meta? table<string, any>

--- @class tend.acp.SessionListResponse
--- @field sessions tend.acp.SessionInfo[]
--- @field nextCursor? string

--- @class tend.acp.PromptCapabilities
--- @field image boolean
--- @field audio boolean
--- @field embeddedContext boolean

--- @class tend.acp.AgentInfo
--- @field name? string
--- @field version? string
--- @field title? string

--- @class tend.acp.AuthMethod
--- @field id string
--- @field name string
--- @field description? string

--- @class tend.acp.McpServer
--- @field name string
--- @field command string
--- @field args string[]
--- @field env tend.acp.EnvVariable[]

--- @class tend.acp.EnvVariable
--- @field name string
--- @field value string

--- @alias tend.acp.StopReason
--- | "end_turn"
--- | "max_tokens"
--- | "max_turn_requests"
--- | "refusal"
--- | "cancelled"

--- @alias tend.acp.ToolKind
--- | "read"
--- | "edit"
--- | "delete"
--- | "move"
--- | "search"
--- | "execute"
--- | "think"
--- | "fetch"
--- | "WebSearch"
--- | "SlashCommand"
--- | "SubAgent"
--- | "other"
--- | "create"
--- | "write"
--- | "Skill"
--- | "switch_mode"

--- @alias tend.acp.ToolCallStatus
--- | "pending"
--- | "in_progress"
--- | "completed"
--- | "failed"

--- @alias tend.acp.PlanEntryStatus
--- | "pending"
--- | "in_progress"
--- | "completed"

--- @alias tend.acp.PlanEntryPriority
--- | "high"
--- | "medium"
--- | "low"

--- @class tend.acp.RawInput
--- @field file_path? string
--- @field filePath? string OpenCode was sending it camelCase
--- @field new_string? string
--- @field newString? string OpenCode was sending it camelCase
--- @field old_string? string
--- @field oldString? string OpenCode was sending it camelCase
--- @field replace_all? boolean
--- @field description? string
--- @field command? string
--- @field url? string Usually from the fetch tool
--- @field prompt? string Usually accompanying the fetch tool, not the web_search
--- @field query? string Usually from the web_search tool
--- @field timeout? number

--- @class tend.acp.ToolCallRegularContent
--- @field type "content"
--- @field content tend.acp.Content

--- @class tend.acp.ToolCallDiffContent
--- @field type "diff"
--- @field path string
--- @field oldText? string
--- @field newText string

--- @alias tend.acp.ACPToolCallContent
--- | tend.acp.ToolCallRegularContent
--- | tend.acp.ToolCallDiffContent

--- @class tend.acp.ToolCallLocation
--- @field path string
--- @field line? number

--- @class tend.acp.PlanEntry
--- @field content string
--- @field priority tend.acp.PlanEntryPriority
--- @field status tend.acp.PlanEntryStatus

--- @class tend.acp.AvailableCommand
--- @field name string
--- @field description string
--- @field input? table<string, any>

--- @class tend.acp.AgentMode
--- @field id string
--- @field name string
--- @field description? string

--- @class tend.acp.Model
--- @field modelId string
--- @field name string
--- @field description string

--- @class tend.acp.ModesInfo
--- @field availableModes tend.acp.AgentMode[]
--- @field currentModeId string

--- @class tend.acp.ModelsInfo
--- @field availableModels tend.acp.Model[]
--- @field currentModelId string

--- @class tend.acp.ConfigOption.Option
--- @field description string
--- @field name string
--- @field value string

--- @alias tend.acp.ConfigOption.Category
--- | "mode"
--- | "model"
--- | "thought_level"

--- @class tend.acp.ConfigOption
--- @field id string
--- @field category tend.acp.ConfigOption.Category
--- @field currentValue string
--- @field description string
--- @field name string
--- @field options tend.acp.ConfigOption.Option[]

--- @class tend.acp.SessionCreationResponse
--- @field sessionId string
--- @field modes? tend.acp.ModesInfo
--- @field models? tend.acp.ModelsInfo
--- @field configOptions? tend.acp.ConfigOption[]

--- @alias tend.acp.ResponseRawParams
--- | { sessionId: string, update: tend.acp.SessionUpdateMessage }
--- | tend.acp.RequestPermission

--- @class tend.acp.ResponseRaw
--- @field id? number
--- @field jsonrpc string
--- @field method? string
--- @field result? table
--- @field error? tend.acp.ACPError
--- @field params? tend.acp.ResponseRawParams

--- Shared base fields for ToolCall and ToolCallUpdate.
--- In the ACP spec, ToolCallUpdate is a partial version where all fields
--- except toolCallId are optional. ToolCall (initial) additionally requires title.
--- @class tend.acp.ToolCallBase
--- @field toolCallId string
--- @field title? string
--- @field kind? tend.acp.ToolKind
--- @field status? tend.acp.ToolCallStatus
--- @field content? tend.acp.ACPToolCallContent[]
--- @field locations? tend.acp.ToolCallLocation[]
--- @field rawInput? tend.acp.RawInput
--- @field rawOutput? table
--- @field _meta? table<string, any>

--- Initial tool call notification (sessionUpdate="tool_call").
--- Per ACP JSON schema, only toolCallId and title are required.
--- @class tend.acp.ToolCallMessage : tend.acp.ToolCallBase
--- @field sessionUpdate "tool_call"

--- Tool call progress update (sessionUpdate="tool_call_update").
--- Only toolCallId is required. All other fields are optional — only changed fields are sent.
--- @class tend.acp.ToolCallUpdate : tend.acp.ToolCallBase
--- @field sessionUpdate "tool_call_update"

--- @class tend.acp.PlanUpdate
--- @field sessionUpdate "plan"
--- @field entries tend.acp.PlanEntry[]

--- @class tend.acp.AvailableCommandsUpdate
--- @field sessionUpdate "available_commands_update"
--- @field availableCommands tend.acp.AvailableCommand[]

--- @class tend.acp.CurrentModeUpdate
--- @field sessionUpdate "current_mode_update"
--- @field currentModeId string

--- @class tend.acp.UsageUpdate
--- @field sessionUpdate "usage_update"
--- @field used number Tokens currently in context
--- @field size number Total context window size in tokens
--- @field cost? { amount: number, currency: string } Cumulative session cost

--- @class tend.acp.SessionInfoUpdate
--- @field sessionUpdate "session_info_update"
--- @field title? string
--- @field updatedAt? string

--- @class tend.acp.ConfigOptionsUpdate
--- @field sessionUpdate "config_option_update"
--- @field configOptions tend.acp.ConfigOption[]

--- @alias tend.acp.SessionUpdateMessage
--- | tend.acp.UserMessageChunk
--- | tend.acp.AgentMessageChunk
--- | tend.acp.AgentThoughtChunk
--- | tend.acp.ToolCallMessage
--- | tend.acp.ToolCallUpdate
--- | tend.acp.PlanUpdate
--- | tend.acp.AvailableCommandsUpdate
--- | tend.acp.CurrentModeUpdate
--- | tend.acp.UsageUpdate
--- | tend.acp.SessionInfoUpdate
--- | tend.acp.ConfigOptionsUpdate

--- @class tend.acp.PermissionOption
--- @field optionId string
--- @field name string
--- @field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

--- Permission request (session/request_permission JSON-RPC request).
--- Per ACP spec, toolCall is a ToolCallUpdate (partial) — same shape used in tool_call_update.
--- @class tend.acp.RequestPermission
--- @field sessionId string
--- @field options tend.acp.PermissionOption[]
--- @field toolCall tend.acp.ToolCallBase

--- @class tend.acp.RequestPermissionOutcome
--- @field outcome "cancelled" | "selected"
--- @field optionId? string

--- @alias tend.acp.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @class tend.acp.ACPError
--- @field code number
--- @field message string
--- @field data? any

--- @alias tend.acp.ClientHandlers.on_session_update fun(update: tend.acp.SessionUpdateMessage): nil
--- @alias tend.acp.ClientHandlers.on_request_permission fun(request: tend.acp.RequestPermission, callback: fun(option_id: string | nil)): nil
--- @alias tend.acp.ClientHandlers.on_error fun(err: tend.acp.ACPError): nil

--- @class tend.Selection
--- @field lines string[] The selected code lines
--- @field start_line integer Starting line number (1-indexed)
--- @field end_line integer Ending line number (1-indexed, inclusive)
--- @field file_path string Relative file path
--- @field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class tend.acp.ClientHandlers
--- @field on_session_update tend.acp.ClientHandlers.on_session_update
--- @field on_request_permission tend.acp.ClientHandlers.on_request_permission
--- @field on_error tend.acp.ClientHandlers.on_error
--- @field on_tool_call fun(tool_call: tend.ui.MessageWriter.ToolCallBlock): nil
--- @field on_tool_call_update fun(tool_call: tend.ui.MessageWriter.ToolCallBlock): nil

--- @class tend.acp.ACPProviderConfig
--- @field name? string Provider name
--- @field transport_type? tend.acp.TransportType
--- @field command? string Command to spawn agent (for stdio)
--- @field args? string[] Arguments for agent command
--- @field env? table<string, string|nil> Environment variables
--- @field timeout? number Request timeout in milliseconds
--- @field reconnect? boolean Enable auto-reconnect
--- @field max_reconnect_attempts? number Maximum reconnection attempts
--- @field auth_method? string Authentication method
--- @field default_mode? string Default mode ID to set on session creation
--- @field initial_model? string Default model ID to set on session creation. When also setting default_thought_level, the thought level is applied AFTER the model change response (because effort/thought_level options can be model-dependent, e.g. Claude rebuilds them on model switch).
--- @field default_thought_level? string Default thought_level / effort value to set on session creation. Validated against the model's options. If `initial_model` is also set, applied after the model change completes.
