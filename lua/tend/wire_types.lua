--[[
  CRITICAL: Type annotations in this file are essential for Lua Language Server support.
  DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- @class tend.wire.ClientInfo
--- @field name string
--- @field version string

--- @class tend.wire.ClientCapabilities
--- @field fs tend.wire.FileSystemCapability
--- @field terminal boolean

--- @class tend.wire.InitializeParams
--- @field protocolVersion number
--- @field clientInfo tend.wire.ClientInfo
--- @field clientCapabilities tend.wire.ClientCapabilities

--- @class tend.wire.InitializeResponse
--- @field protocolVersion number
--- @field agentCapabilities tend.wire.AgentCapabilities
--- @field agentInfo tend.wire.AgentInfo
--- @field authMethods? tend.wire.AuthMethod[]

--- @class tend.wire.FileSystemCapability
--- @field readTextFile boolean
--- @field writeTextFile boolean

--- @class tend.wire.SessionCapabilities
--- @field list? boolean

--- @class tend.wire.AgentCapabilities
--- @field loadSession boolean
--- @field sessionCapabilities? tend.wire.SessionCapabilities
--- @field promptCapabilities tend.wire.PromptCapabilities

--- @class tend.wire.SessionInfo
--- @field sessionId string
--- @field cwd string
--- @field title? string
--- @field updatedAt? string
--- @field _meta? table<string, any>

--- @class tend.wire.SessionListResponse
--- @field sessions tend.wire.SessionInfo[]
--- @field nextCursor? string

--- @class tend.wire.PromptCapabilities
--- @field image boolean
--- @field audio boolean
--- @field embeddedContext boolean

--- @class tend.wire.AgentInfo
--- @field name? string
--- @field version? string
--- @field title? string

--- @class tend.wire.AuthMethod
--- @field id string
--- @field name string
--- @field description? string

--- @class tend.wire.McpServer
--- @field name string
--- @field command string
--- @field args string[]
--- @field env tend.wire.EnvVariable[]

--- @class tend.wire.EnvVariable
--- @field name string
--- @field value string

--- @alias tend.wire.StopReason
--- | "end_turn"
--- | "max_tokens"
--- | "max_turn_requests"
--- | "refusal"
--- | "cancelled"

--- @alias tend.wire.ToolKind
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

--- @alias tend.wire.ToolCallStatus
--- | "pending"
--- | "in_progress"
--- | "completed"
--- | "failed"

--- @alias tend.wire.PlanEntryStatus
--- | "pending"
--- | "in_progress"
--- | "completed"

--- @alias tend.wire.PlanEntryPriority
--- | "high"
--- | "medium"
--- | "low"

--- @class tend.wire.RawInput
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

--- @class tend.wire.ToolCallRegularContent
--- @field type "content"
--- @field content tend.wire.Content

--- @class tend.wire.ToolCallDiffContent
--- @field type "diff"
--- @field path string
--- @field oldText? string
--- @field newText string

--- @alias tend.wire.ACPToolCallContent
--- | tend.wire.ToolCallRegularContent
--- | tend.wire.ToolCallDiffContent

--- @class tend.wire.ToolCallLocation
--- @field path string
--- @field line? number

--- @class tend.wire.PlanEntry
--- @field content string
--- @field priority tend.wire.PlanEntryPriority
--- @field status tend.wire.PlanEntryStatus

--- @class tend.wire.AvailableCommand
--- @field name string
--- @field description string
--- @field input? table<string, any>

--- @class tend.wire.AgentMode
--- @field id string
--- @field name string
--- @field description? string

--- @class tend.wire.Model
--- @field modelId string
--- @field name string
--- @field description string

--- @class tend.wire.ModesInfo
--- @field availableModes tend.wire.AgentMode[]
--- @field currentModeId string

--- @class tend.wire.ModelsInfo
--- @field availableModels tend.wire.Model[]
--- @field currentModelId string

--- @class tend.wire.ConfigOption.Option
--- @field description string
--- @field name string
--- @field value string

--- @alias tend.wire.ConfigOption.Category
--- | "mode"
--- | "model"
--- | "thought_level"

--- @class tend.wire.ConfigOption
--- @field id string
--- @field category tend.wire.ConfigOption.Category
--- @field currentValue string
--- @field description string
--- @field name string
--- @field options tend.wire.ConfigOption.Option[]

--- @class tend.wire.SessionCreationResponse
--- @field sessionId string
--- @field modes? tend.wire.ModesInfo
--- @field models? tend.wire.ModelsInfo
--- @field configOptions? tend.wire.ConfigOption[]

--- @alias tend.wire.ResponseRawParams
--- | { sessionId: string, update: tend.wire.SessionUpdateMessage }
--- | tend.wire.RequestPermission

--- @class tend.wire.ResponseRaw
--- @field id? number
--- @field jsonrpc string
--- @field method? string
--- @field result? table
--- @field error? tend.wire.ACPError
--- @field params? tend.wire.ResponseRawParams

--- Shared base fields for ToolCall and ToolCallUpdate.
--- In the ACP spec, ToolCallUpdate is a partial version where all fields
--- except toolCallId are optional. ToolCall (initial) additionally requires title.
--- @class tend.wire.ToolCallBase
--- @field toolCallId string
--- @field title? string
--- @field kind? tend.wire.ToolKind
--- @field status? tend.wire.ToolCallStatus
--- @field content? tend.wire.ACPToolCallContent[]
--- @field locations? tend.wire.ToolCallLocation[]
--- @field rawInput? tend.wire.RawInput
--- @field rawOutput? table
--- @field _meta? table<string, any>

--- Initial tool call notification (sessionUpdate="tool_call").
--- Per ACP JSON schema, only toolCallId and title are required.
--- @class tend.wire.ToolCallMessage : tend.wire.ToolCallBase
--- @field sessionUpdate "tool_call"

--- Tool call progress update (sessionUpdate="tool_call_update").
--- Only toolCallId is required. All other fields are optional — only changed fields are sent.
--- @class tend.wire.ToolCallUpdate : tend.wire.ToolCallBase
--- @field sessionUpdate "tool_call_update"

--- @class tend.wire.PlanUpdate
--- @field sessionUpdate "plan"
--- @field entries tend.wire.PlanEntry[]

--- @class tend.wire.AvailableCommandsUpdate
--- @field sessionUpdate "available_commands_update"
--- @field availableCommands tend.wire.AvailableCommand[]

--- @class tend.wire.CurrentModeUpdate
--- @field sessionUpdate "current_mode_update"
--- @field currentModeId string

--- @class tend.wire.UsageUpdate
--- @field sessionUpdate "usage_update"
--- @field used number Tokens currently in context
--- @field size number Total context window size in tokens
--- @field cost? { amount: number, currency: string } Cumulative session cost

--- @class tend.wire.SessionInfoUpdate
--- @field sessionUpdate "session_info_update"
--- @field title? string
--- @field updatedAt? string

--- @class tend.wire.ConfigOptionsUpdate
--- @field sessionUpdate "config_option_update"
--- @field configOptions tend.wire.ConfigOption[]

--- @alias tend.wire.SessionUpdateMessage
--- | tend.wire.UserMessageChunk
--- | tend.wire.AgentMessageChunk
--- | tend.wire.AgentThoughtChunk
--- | tend.wire.ToolCallMessage
--- | tend.wire.ToolCallUpdate
--- | tend.wire.PlanUpdate
--- | tend.wire.AvailableCommandsUpdate
--- | tend.wire.CurrentModeUpdate
--- | tend.wire.UsageUpdate
--- | tend.wire.SessionInfoUpdate
--- | tend.wire.ConfigOptionsUpdate

--- @class tend.wire.PermissionOption
--- @field optionId string
--- @field name string
--- @field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

--- Permission request (session/request_permission JSON-RPC request).
--- Per ACP spec, toolCall is a ToolCallUpdate (partial) — same shape used in tool_call_update.
--- @class tend.wire.RequestPermission
--- @field sessionId string
--- @field options tend.wire.PermissionOption[]
--- @field toolCall tend.wire.ToolCallBase

--- @class tend.wire.RequestPermissionOutcome
--- @field outcome "cancelled" | "selected"
--- @field optionId? string

--- @alias tend.wire.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @class tend.wire.ACPError
--- @field code number
--- @field message string
--- @field data? any

--- @alias tend.wire.ClientHandlers.on_session_update fun(update: tend.wire.SessionUpdateMessage): nil
--- @alias tend.wire.ClientHandlers.on_request_permission fun(request: tend.wire.RequestPermission, callback: fun(option_id: string | nil)): nil
--- @alias tend.wire.ClientHandlers.on_error fun(err: tend.wire.ACPError): nil

--- @class tend.Selection
--- @field lines string[] The selected code lines
--- @field start_line integer Starting line number (1-indexed)
--- @field end_line integer Ending line number (1-indexed, inclusive)
--- @field file_path string Relative file path
--- @field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class tend.wire.ClientHandlers
--- @field on_session_update tend.wire.ClientHandlers.on_session_update
--- @field on_request_permission tend.wire.ClientHandlers.on_request_permission
--- @field on_error tend.wire.ClientHandlers.on_error
--- @field on_tool_call fun(tool_call: tend.ui.MessageWriter.ToolCallBlock): nil
--- @field on_tool_call_update fun(tool_call: tend.ui.MessageWriter.ToolCallBlock): nil

--- @class tend.wire.ACPProviderConfig
--- @field name? string Provider name
--- @field transport_type? tend.wire.TransportType
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

--- Content vocabulary (the ACP-style prompt/message content the UI renders),
--- relocated here from the removed in-plugin ACP layer.

--- @alias tend.wire.Annotations.Audience "user" | "assistant"

--- @class tend.wire.Annotations
--- @field audience? tend.wire.Annotations.Audience[]
--- @field lastModified? string
--- @field priority? number

--- @class tend.wire.TextContent
--- @field type "text"
--- @field text string
--- @field annotations? tend.wire.Annotations

--- @class tend.wire.ImageContent
--- @field type "image"
--- @field data string
--- @field mimeType string
--- @field uri? string
--- @field annotations? tend.wire.Annotations

--- @class tend.wire.AudioContent
--- @field type "audio"
--- @field data string
--- @field mimeType string
--- @field annotations? tend.wire.Annotations

--- @class tend.wire.EmbeddedResource
--- @field uri string
--- @field text string
--- @field blob? string
--- @field mimeType? string

--- @class tend.wire.ResourceLinkContent
--- @field type "resource_link"
--- @field uri string
--- @field name string
--- @field description? string
--- @field mimeType? string
--- @field size? number
--- @field title? string
--- @field annotations? tend.wire.Annotations

--- @class tend.wire.ResourceContent
--- @field type "resource"
--- @field resource tend.wire.EmbeddedResource
--- @field annotations? tend.wire.Annotations

--- @alias tend.wire.Content
--- | tend.wire.TextContent
--- | tend.wire.ImageContent
--- | tend.wire.AudioContent
--- | tend.wire.ResourceLinkContent
--- | tend.wire.ResourceContent

--- @class tend.wire.UserMessageChunk
--- @field sessionUpdate "user_message_chunk"
--- @field content tend.wire.Content

--- @class tend.wire.AgentMessageChunk
--- @field sessionUpdate "agent_message_chunk"
--- @field content tend.wire.Content

--- @class tend.wire.AgentThoughtChunk
--- @field sessionUpdate "agent_thought_chunk"
--- @field content tend.wire.Content

--- Native Neovim completion item (vim.fn.complete() dictionary; see
--- |complete-items|), used by the slash/file completion sources.
--- @class tend.wire.CompletionItem
--- @field word string The text to insert (mandatory)
--- @field menu string Description shown in completion menu
--- @field info string Full description shown in popup window
--- @field kind string Type/category of completion item
--- @field icase number 1 for case-insensitive, 0 for case-sensitive

--- @alias tend.wire.TransportType "stdio" | "tcp" | "websocket"
