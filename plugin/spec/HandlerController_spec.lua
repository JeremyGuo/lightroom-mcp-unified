local helper = require 'spec_helper'

local function setup(options)
    options = options or {}
    local sliders={ Exposure=0, Contrast=0, Temperature=6000, Tint=0, local_Exposure=0,
        LensBlurActive=0, LensBlurAmount=0, LensBlurCatEye=0, LensBlurHighlightsBoost=0 }
    local settings={ Exposure2012=0, Contrast2012=0, Temperature=6000, Tint=0, CropTop=0, CropLeft=0, CropBottom=1, CropRight=1 }
    local writes, selected, mask, calls = {}, nil, nil, {}
    local photo={ localIdentifier=42, getDevelopSettings=function() return settings end,
        getFormattedMetadata=function() return 'sample.NEF' end, getRawMetadata=function() return 3 end,
        applyDevelopSettings=function(_, update) for k,v in pairs(update) do settings[k]=v end end }
    local active=photo
    selected={ photo }
    local catalog={ getTargetPhoto=function() return active end, getTargetPhotos=function() return selected end,
        withWriteAccessDo=function(_, _, fn) fn() end }
    local state={ denoiseState=false, denoiseEnabled=true, rawDetailsState=false, rawDetailsEnabled=true,
        superResState=false, superResEnabled=true, enhanceIsRunning=false }
    local controller={
        getValue=function(key) if sliders[key] == nil then error('Unsupported slider') end; return sliders[key] end,
        getRange=function(key)
            if sliders[key] == nil then error('Unsupported slider') end
            if key == 'Temperature' then return 2000,50000 end
            if key == 'Exposure' or key == 'local_Exposure' then return -5,5 end
            return -100,100
        end,
        setValue=function(key,value)
            if options.reject == key then error('SDK rejected change') end
            writes[#writes+1]=key
            if not options.ignoreWrites then sliders[key]=value end
        end,
        getSelectedMask=function() return mask end, goToMasking=function() end,
        createNewMask=function(kind, subtype) calls[#calls+1]={kind,subtype}; if options.selectNewMask ~= false then mask='new-mask' end end,
        setAutoTone=function() sliders.Exposure=0.8 end,
        resetAllDevelopAdjustments=function() sliders.Exposure=0 end,
        getEnhancePanelState=function() return state end,
        toggleEnhance=function(name,amount) calls[#calls+1]={name,amount}; state[name .. 'State']=not state[name .. 'State'] end,
        changeDenoiseAmount=function(amount) state.denoiseAmount=amount end,
        setLensBlurBokeh=function(name) calls.bokeh=name end,
        getSelectedLensBlurBokeh=function() return calls.bokeh end,
    }
    local modules={
        LrApplication={ activeCatalog=function() return catalog end, versionString=function() return '15.0 mock' end },
        LrApplicationView={ getCurrentModuleName=function() return 'develop' end, switchToModule=function() end },
        LrDevelopController=controller, LrTasks={ pcall=pcall, sleep=function() end },
    }
    for key,value in pairs(options.imports or {}) do modules[key]=value end
    helper.installImport(modules)
    package.loaded.HandlerController=nil
    return require 'HandlerController', { sliders=sliders, writes=writes, settings=settings, calls=calls, state=state,
        controller=controller, selectMask=function(id) mask=id end, setActive=function(p) active=p end,
        setSelection=function(p) selected=p end, photo=photo }
end

describe('Unified controller', function()
    it('uses case-insensitive aliases and reads back writes', function()
        local h,s=setup()
        local result=h.applySettings({ settings={ exposure2012=1.25, CONTRAST=20 } })
        assert.is_true(result.success); assert.are.equal(1.25,s.sliders.Exposure)
        assert.are.equal(20,result.applied.Contrast)
    end)
    it('validates all parameters before writing anything', function()
        local h,s=setup()
        assert.has_error(function() h.applySettings({settings={Exposure=1,Magic=4}}) end)
        assert.are.equal(0,#s.writes)
        assert.has_error(function() h.applySettings({settings={Exposure=7}}) end)
        assert.are.equal(0,#s.writes)
    end)
    it('does not silently accept duplicate aliases', function()
        local h,s=setup()
        assert.has_error(function() h.applySettings({settings={Exposure=1,Exposure2012=2}}) end)
        assert.are.equal(0,#s.writes)
    end)
    it('rejects stale photo IDs and empty selections', function()
        local h,s=setup()
        assert.has_error(function() h.applySettings({photo_id='43',settings={Exposure=1}}) end)
        s.setActive(nil)
        assert.has_error(function() h.batchApplySettings({settings={Exposure=1}}) end)
        assert.are.equal(0,#s.writes)
    end)
    it('reports SDK rejection and silent no-ops as failures', function()
        local h=setup({reject='Exposure'})
        assert.is_false(h.applySettings({settings={Exposure=1}}).success)
        h=setup({ignoreWrites=true})
        assert.is_false(h.applySettings({settings={Exposure=1}}).success)
    end)
    it('translates UI names to correct catalog names for batch editing', function()
        local h,s=setup()
        assert.is_true(h.batchApplySettings({settings={Exposure=0.7}}).success)
        assert.are.equal(0.7,s.settings.Exposure2012)
        assert.is_nil(s.settings.Exposure)
    end)
    it('checks crop bounds against existing values before applying', function()
        local h,s=setup()
        assert.has_error(function() h.crop({CropTop=0.8,CropBottom=0.2}) end)
        assert.has_error(function() h.crop({}) end)
        assert.are.equal(0,s.settings.CropTop)
        assert.is_true(h.crop({CropTop=0.1,angle=3}).success)
        assert.are.equal(0.1,s.settings.CropTop); assert.are.equal(3,s.settings.CropAngle)
    end)
    it('does not apply adjustments until a manual mask is drawn', function()
        local h,s=setup()
        local result=h.addMask({maskType='gradient',adjustments={Exposure=-1}})
        assert.are.equal('requires_user_interaction',result.status)
        assert.is_false(result.adjustments_applied); assert.are.equal(0,#s.writes)
    end)
    it('rejects ignored geometry instead of pretending it was used', function()
        local h,s=setup()
        assert.has_error(function() h.addMask({maskType='gradient',params={angle=20}}) end)
        assert.are.equal(0,#s.calls)
    end)
    it('waits for a distinct selected AI mask before applying local settings', function()
        local h,s=setup()
        s.selectMask('old-mask')
        local result=h.addMask({maskType='sky',adjustments={Exposure=-1}})
        assert.are.equal('new-mask',result.mask_id)
        assert.are.equal(-1,s.sliders.local_Exposure)
        assert.are.same({'aiSelection','sky'},s.calls[1])
    end)
    it('never writes to the old mask when the new one remains pending', function()
        local h,s=setup({selectNewMask=false})
        s.selectMask('old-mask')
        local result=h.addMask({maskType='sky',adjustments={Exposure=-1}})
        assert.are.equal('pending',result.status); assert.are.equal(0,#s.writes)
    end)
    it('requires an actual mask selection for local adjustments', function()
        local h,s=setup()
        assert.has_error(function() h.updateMask({adjustments={Exposure=1}}) end)
        s.selectMask('mask')
        assert.is_true(h.updateMask({adjustments={Exposure=1}}).success)
        assert.has_error(function() h.updateMask({adjustments={Vibrance=1}}) end)
    end)
    it('uses documented Enhance toggles and does not toggle an already enabled feature off', function()
        local h,s=setup()
        assert.are.equal('submitted',h.enhance({denoise=true,denoiseAmount=50}).status)
        assert.are.same({'denoise',50},s.calls[1])
        h.enhance({denoise=true})
        assert.are.equal(1,#s.calls)
        assert.is_true(s.state.denoiseState)
    end)
    it('rejects conflicting/disabled Enhance operations before changes', function()
        local h,s=setup()
        assert.has_error(function() h.enhance({denoise=true,superRes=true}) end)
        s.state.denoiseEnabled=false
        assert.has_error(function() h.enhance({denoise=true}) end)
        assert.are.equal(0,#s.calls)
    end)
    it('fails explicitly when new runtime APIs are absent', function()
        local h,s=setup();s.controller.toggleEnhance=nil
        assert.has_error(function() h.enhance({denoise=true}) end)
        assert.is_false(h.capabilities({}).methods.toggleEnhance)
    end)
    it('does not silently ignore unsupported focal-range automation', function()
        local h,s=setup()
        assert.has_error(function() h.lensBlur({focalRangeFromSubject=true}) end)
        assert.are.equal(0,#s.writes)
        assert.is_true(h.lensBlur({amount=50,bokeh='Circle'}).success)
        assert.are.equal(1,s.sliders.LensBlurActive)
    end)
end)

describe('Preview render lifecycle', function()
    local function preview(options)
        options=options or {}
        local temporary=os.tmpname()
        local f=assert(io.open(temporary,'wb'));f:write(options.bytes or string.char(255,216,255,224,255,217));f:close()
        local seen={}
        local handler=setup({imports={
            LrExportSession=function(config)
                seen.config=config
                return {renditions=function()
                    local once=false
                    return function()
                        if once then return nil end;once=true
                        return 1,{waitForRender=function() return not options.fail,options.fail and 'renderer failed' or temporary end}
                    end
                end}
            end,
            LrPathUtils={child=function(a,b) return a .. '/' .. b end,getStandardFilePath=function() return '/temp' end},
            LrUUID={generateUUID=function() return 'preview-test' end},
            LrStringUtils={encodeBase64=function(data) seen.bytes=data;return '/9j/4P/Z' end},
            LrFileUtils={createAllDirectories=function() return true end,delete=function(path) seen.deleted=path;os.remove(temporary);return true end},
        }})
        return handler,seen,temporary
    end
    it('uses the current render and removes only its unique temporary folder', function()
        local h,s=preview()
        local result=h.exportPreview({size=256})
        assert.is_true(result.success);assert.are.equal('image/jpeg',result.mime_type)
        assert.are.equal(0.85,s.config.exportSettings.LR_jpeg_quality)
        assert.are.equal(256,s.config.exportSettings.LR_size_maxHeight)
        assert.are.equal('/temp/lightroom-mcp-unified-preview-test',s.deleted)
        assert.are.equal(6,#s.bytes)
    end)
    it('cleans up when rendering fails', function()
        local h,s=preview({fail=true})
        assert.has_error(function() h.exportPreview({}) end)
        assert.is_not_nil(s.deleted)
    end)
    it('rejects non-JPEG render data and cleans up', function()
        local h,s=preview({bytes='not an image'})
        assert.has_error(function() h.exportPreview({}) end)
        assert.is_not_nil(s.deleted)
    end)
end)
