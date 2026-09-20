-- Reload creates a new Lua environment; it does not terminate old async tasks.
-- Signal the outgoing environment before the new one binds sockets/token.
local provider = require 'PluginInfoProvider'
provider.shutdown()
