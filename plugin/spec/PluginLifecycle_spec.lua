describe('Plugin lifecycle hooks', function()
    it('signals the outgoing Lua environment on unload and disable', function()
        local info=dofile('plugin/LightroomMCPUnified.lrplugin/Info.lua')
        local stopped=0
        local previous=package.loaded.PluginInfoProvider
        package.loaded.PluginInfoProvider={shutdown=function() stopped=stopped+1 end}
        dofile('plugin/LightroomMCPUnified.lrplugin/' .. info.LrShutdownPlugin)
        dofile('plugin/LightroomMCPUnified.lrplugin/' .. info.LrDisablePlugin)
        package.loaded.PluginInfoProvider=previous
        assert.are.equal(2,stopped)
    end)
    it('provides a File menu entry so forced initialization works from Develop', function()
        local info=dofile('plugin/LightroomMCPUnified.lrplugin/Info.lua')
        assert.is_true(info.LrForceInitPlugin)
        assert.is_string(info.LrExportMenuItems[1].file)
        assert.is_string(info.LrInitPlugin)
    end)
end)
