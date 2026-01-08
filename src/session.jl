# ============================================================================
# Session Management Module
# ============================================================================
#
# Implements MCP session lifecycle management according to the specification:
# - Session initialization with protocol version negotiation
# - Capability negotiation
# - Session state management (uninitialized, initializing, initialized, closed)
# - Proper cleanup on session end

module Session

using JSON
using Dates
using UUIDs

export MCPSession,
    SessionState, initialize_session!, close_session!, get_session_info, update_activity!

# Session states
@enum SessionState begin
    UNINITIALIZED  # Session created but not initialized
    INITIALIZING   # Initialize request received, processing
    INITIALIZED    # Successfully initialized and ready
    CLOSED         # Session has been closed
end

"""
    MCPSession

Represents an MCP protocol session with a client.

# Fields
- `id::String`: Unique session identifier (UUID)
- `state::SessionState`: Current session state
- `protocol_version::String`: Negotiated protocol version
- `client_info::Dict{String,Any}`: Client information from initialize
- `server_capabilities::Dict{String,Any}`: Server capabilities advertised to client
- `client_capabilities::Dict{String,Any}`: Client capabilities received during init
- `created_at::DateTime`: Session creation timestamp
- `initialized_at::Union{DateTime,Nothing}`: Session initialization timestamp
- `closed_at::Union{DateTime,Nothing}`: Session close timestamp
- `target_repl_id::Union{String,Nothing}`: Target REPL ID for proxy routing (proxy only)
- `last_activity::DateTime`: Last time this session was active
"""
mutable struct MCPSession
    id::String
    state::SessionState
    protocol_version::String
    client_info::Dict{String, Any}
    server_capabilities::Dict{String, Any}
    client_capabilities::Dict{String, Any}
    created_at::DateTime
    initialized_at::Union{DateTime, Nothing}
    closed_at::Union{DateTime, Nothing}
    target_repl_id::Union{String, Nothing}
    last_activity::DateTime
end

"""
    MCPSession(; target_repl_id::Union{String,Nothing}=nothing) -> MCPSession

Create a new uninitialized MCP session.

# Arguments
- `target_repl_id::Union{String,Nothing}=nothing`: Optional target REPL ID for proxy routing
"""
function MCPSession(; target_repl_id::Union{String, Nothing} = nothing)
    now_time = now()
    return MCPSession(
        string(uuid4()),                    # id
        UNINITIALIZED,                      # state
        "",                                 # protocol_version
        Dict{String, Any}(),                 # client_info
        get_server_capabilities(),          # server_capabilities
        Dict{String, Any}(),                 # client_capabilities
        now_time,                           # created_at
        nothing,                            # initialized_at
        nothing,                            # closed_at
        target_repl_id,                     # target_repl_id
        now_time,                           # last_activity
    )
end

"""
    get_server_capabilities() -> Dict{String,Any}

Return the server's capabilities to advertise to clients.
"""
function get_server_capabilities()
    return Dict{String, Any}(
        "tools" => Dict{String, Any}(
            "listChanged" => true,  # We support tools/list_changed notifications
        ),
        "prompts" => Dict{String, Any}(),  # We support prompts
        "resources" => Dict{String, Any}(),  # We support resources
        "logging" => Dict{String, Any}(),  # We support logging
        "experimental" => Dict{String, Any}(
            "vscode_integration" => true,  # Custom VS Code integration
            "supervisor_mode" => true,     # Multi-agent supervision
            "proxy_routing" => true,       # Proxy-based routing
        ),
    )
end

"""
    initialize_session!(session::MCPSession, params::Dict) -> Dict{String,Any}

Initialize a session with protocol version and capability negotiation.

# Arguments
- `session::MCPSession`: The session to initialize
- `params::Dict`: Initialize request parameters containing:
  - `protocolVersion`: Required protocol version
  - `capabilities`: Client capabilities
  - `clientInfo`: Client information (name, version)

# Returns
Dictionary containing initialization response with:
- `protocolVersion`: Server's protocol version
- `capabilities`: Server capabilities
- `serverInfo`: Server information

# Throws
- `ErrorException`: If session is not in UNINITIALIZED state
- `ErrorException`: If protocol version is not supported
"""
function initialize_session!(session::MCPSession, params::Dict)
    # Validate session state
    if session.state != UNINITIALIZED
        error("Session already initialized or closed")
    end

    session.state = INITIALIZING

    # Extract and validate protocol version
    client_version = get(params, "protocolVersion", nothing)
    if client_version === nothing
        session.state = UNINITIALIZED
        error("Missing required parameter: protocolVersion")
    end

    # Server actually supports these versions (in order from oldest to newest)
    # We negotiate down to the highest mutually supported version
    server_supported_versions = ["2024-11-05", "2025-06-18"]
    latest_supported = last(server_supported_versions)

    # Version negotiation: find the highest version that both client and server support
    # If client requests a newer version, negotiate down to the highest we support
    # If client requests an older or equal version we support, use that
    supported_version = nothing

    if client_version in server_supported_versions
        # Client requested a version we fully support
        supported_version = client_version
    elseif client_version > latest_supported
        # Client requested newer version - negotiate down to highest we support
        supported_version = latest_supported
        @info "Protocol version negotiation" client_requested = client_version server_negotiated = supported_version
    else
        # Client requested an unsupported version
        session.state = UNINITIALIZED
        error(
            "Unsupported protocol version: $client_version. Server supports: $(join(server_supported_versions, ", "))",
        )
    end

    # Store client capabilities
    session.client_capabilities = get(params, "capabilities", Dict{String, Any}())

    # Store client info
    session.client_info = get(params, "clientInfo", Dict{String, Any}())

    # Mark session as initialized
    session.protocol_version = supported_version
    session.state = INITIALIZED
    session.initialized_at = now()

    # Return initialization response
    return Dict{String, Any}(
        "protocolVersion" => supported_version,
        "capabilities" => session.server_capabilities,
        "serverInfo" => Dict{String, Any}("name" => "MCPRepl", "version" => get_version()),
    )
end

"""
    close_session!(session::MCPSession)

Close a session and clean up resources.
"""
function close_session!(session::MCPSession)
    if session.state == CLOSED
        @warn "Session already closed" session_id = session.id
        return
    end

    session.state = CLOSED
    session.closed_at = now()
    return @info "Session closed" session_id = session.id duration =
        session.closed_at - session.created_at
end

"""
    get_session_info(session::MCPSession) -> Dict{String,Any}

Get information about the current session.
"""
function get_session_info(session::MCPSession)
    return Dict{String, Any}(
        "id" => session.id,
        "state" => string(session.state),
        "protocol_version" => session.protocol_version,
        "client_info" => session.client_info,
        "created_at" => session.created_at,
        "initialized_at" => session.initialized_at,
        "closed_at" => session.closed_at,
        "uptime" =>
            session.initialized_at === nothing ? nothing :
            (
                session.closed_at === nothing ? now() - session.initialized_at :
                session.closed_at - session.initialized_at
            ),
    )
end

"""
    update_activity!(session::MCPSession)

Update the last activity timestamp for a session.
"""
function update_activity!(session::MCPSession)
    return session.last_activity = now()
end

"""
    get_version() -> String

Get the MCPRepl version string.
"""
function get_version()
    # Try to get version from parent module if available
    if isdefined(Main, :MCPRepl) && isdefined(Main.MCPRepl, :version_info)
        return Main.MCPRepl.version_info()
    end
    return "0.4.0"
end

end # module Session
