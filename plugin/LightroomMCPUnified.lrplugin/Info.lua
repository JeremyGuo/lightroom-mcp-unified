return {
    LrSdkVersion = 15.0,
    LrSdkMinimumVersion = 8.0,

    LrToolkitIdentifier = 'io.github.jeremyguo.lightroom-mcp-unified',
    LrPluginName = "Lightroom MCP Unified",

    LrPluginInfoUrl = "https://github.com/JeremyGuo/lightroom-mcp-unified",

    VERSION = { major=0, minor=1, revision=0, build=0 },

    LrPluginInfoProvider = 'PluginInfoProvider.lua',
    LrInitPlugin = 'PluginInit.lua',
    LrShutdownPlugin = 'PluginShutdown.lua',
    LrDisablePlugin = 'PluginShutdown.lua',
    LrEnablePlugin = 'PluginInit.lua',
    -- 15.5.1 launched in Develop does not eagerly load a Library-only menu
    -- plugin. Keep a File menu entry as well (verified with an A/B restart).
    LrForceInitPlugin = true,

    LrExportMenuItems = {
        { title = "Lightroom MCP Unified — Show Status", file = "MenuShowStatus.lua" },
    },

    LrLibraryMenuItems = {
        {
            title = "Lightroom MCP Unified — Show Status",
            file = "MenuShowStatus.lua",
        },
    },
}
