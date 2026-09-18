return {
    LrSdkVersion = 15.0,
    LrSdkMinimumVersion = 8.0,

    LrToolkitIdentifier = 'io.github.jeremyguo.lightroom-mcp-unified',
    LrPluginName = "Lightroom MCP Unified",

    LrPluginInfoUrl = "https://github.com/JeremyGuo/lightroom-mcp-unified",

    VERSION = { major=0, minor=1, revision=0, build=0 },

    LrPluginInfoProvider = 'PluginInfoProvider.lua',
    LrInitPlugin = 'PluginInit.lua',
    -- LrForceInitPlugin forces eager load on Lr launch, but ONLY if the
    -- plugin also exposes at least one menu item — see LrLibraryMenuItems
    -- below. Adobe's own remote_control_socket sample uses this pattern.
    LrForceInitPlugin = true,

    LrLibraryMenuItems = {
        {
            title = "Lightroom MCP Unified — Show Status",
            file = "MenuShowStatus.lua",
        },
    },
}
