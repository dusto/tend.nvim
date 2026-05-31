--- Mock implementation of tend.acp.ACPTransportModule for testing
--- @class tend.acp.ACPTransportModuleMock
local M = {}

--- Create a mock stdio transport for testing
--- @param config tend.acp.StdioTransportConfig
--- @param callbacks tend.acp.TransportCallbacks
--- @return tend.acp.ACPTransportInstance
function M.create_stdio_transport(config, callbacks)
    --- @type tend.acp.ACPTransportInstance
    local transport = {
        stdin = nil,
        stdout = nil,
        process = nil,
        _config = config,
        _callbacks = callbacks,
        _started = false,
        _stopped = false,
        callbacks = callbacks,
    }

    --- @param _data string
    function transport:send(_data)
        if self._stopped then
            return false
        end
        return true
    end

    function transport:start()
        self._started = true
        self._callbacks.on_state_change("connecting")
    end

    function transport:stop()
        self._stopped = true
        self._callbacks.on_state_change("disconnected")
    end

    return transport
end

return M
