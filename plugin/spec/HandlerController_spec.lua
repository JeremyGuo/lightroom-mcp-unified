local helper = require 'spec_helper'

local function setup(options)
    options = options or {}
    local sliders={ Exposure=0, Contrast=0, Temperature=6000, Tint=0, local_Exposure=0,
        LensBlurActive=false, LensBlurAmount=0, LensBlurCatEye=0, LensBlurHighlightsBoost=0 }
    local settings={ Exposure2012=0, Contrast2012=0, Temperature=6000, Tint=0, CropTop=0, CropLeft=0, CropBottom=1, CropRight=1 }
    local writes, selected, mask, calls = {}, nil, nil, {}
    local pending = {}
    local loading=options.loadingTicks or 0
    local clock=0
    local queuedAction
    local function commit()
        for key,value in pairs(pending) do settings[key]=value end
    end
    local photo={ localIdentifier=42, getDevelopSettings=function() return settings end,
        isAvailableForEditing=function() return loading==0 end,
        getFormattedMetadata=function() return 'sample.NEF' end, getRawMetadata=function() return 3 end,
        applyDevelopSettings=function(_, update) for k,v in pairs(update) do settings[k]=v end end }
    local active=photo
    selected={ photo }
    local catalog={ getTargetPhoto=function() return active end, getTargetPhotos=function() return selected end,
        withWriteAccessDo=function(_, _, fn) fn() end }
    local state={ denoiseState=false, denoiseEnabled=true, rawDetailsState=false, rawDetailsEnabled=true,
        superResState=false, superResEnabled=true, enhanceIsRunning=false, enhanceNeedsUpdate=false,denoiseAmount=50 }
    local controller={
        getValue=function(key) if loading>0 then return nil end; if sliders[key] == nil then error('Unsupported slider') end; return sliders[key] end,
        getRange=function(key)
            if loading>0 then return nil end
            if sliders[key] == nil then error('Unsupported slider') end
            if key == 'Temperature' then if settings.Temperature==nil then return -100,100 end;return 2000,50000 end
            if key == 'Exposure' or key == 'local_Exposure' then return -5,5 end
            return -100,100
        end,
        setValue=function(key,value)
            if options.reject == key then error('SDK rejected change') end
            writes[#writes+1]=key
            if not options.ignoreWrites then
                sliders[key]=value
                local catalogKey=({Exposure='Exposure2012',Contrast='Contrast2012'})[key] or key
                if settings[catalogKey] ~= nil then pending[catalogKey]=value end
                if not options.deferCatalogWrites then commit() end
                if options.busyAfterWrite then loading=2 end
            end
        end,
        getSelectedMask=function() return mask end, goToMasking=function() end,
        createNewMask=function(kind, subtype) calls[#calls+1]={kind,subtype}; if options.selectNewMask ~= false then mask='new-mask' end end,
        setAutoTone=function()
            local fn=function() sliders.Exposure=0.8;settings.Exposure2012=0.8 end
            if options.asyncActions then loading=2;queuedAction=fn else fn() end
        end,
        resetAllDevelopAdjustments=function()
            local fn=function() sliders.Exposure=0;settings.Exposure2012=0;settings.CropTop=0 end
            if options.asyncActions then loading=2;queuedAction=fn else fn() end
        end,
        getEnhancePanelState=function() return state end,
        toggleEnhance=function(name,amount)
            calls[#calls+1]={name,amount}
            if not options.ignoreEnhance then state[name .. 'State']=not state[name .. 'State'] end
            if name=='denoise' and amount then state.denoiseAmount=amount end
            loading=options.enhanceTicks or 0
            state.enhanceIsRunning=options.enhanceNeverFinishes or loading>0
        end,
        changeDenoiseAmount=function(amount) state.denoiseAmount=amount end,
        setLensBlurBokeh=function(name) calls.bokeh=name end,
        getSelectedLensBlurBokeh=function() return calls.bokeh end,
    }
    local modules={
        LrApplication={ activeCatalog=function() return catalog end, versionString=function() return '15.0 mock' end },
        LrApplicationView={ getCurrentModuleName=function() return 'develop' end, switchToModule=function() end },
        LrDate={currentTime=function() return clock end},
        LrDevelopController=controller, LrTasks={ pcall=pcall, sleep=function(seconds)
            clock=clock+(seconds or 0)
            calls.sleeps=(calls.sleeps or 0)+1
            if loading>0 then loading=loading-1 end
            state.enhanceIsRunning=options.enhanceNeverFinishes or loading>0
            if loading==0 and queuedAction then local fn=queuedAction;queuedAction=nil;fn() end
            if not options.neverCommit then commit() end
            if options.onSleep then options.onSleep() end
        end },
    }
    for key,value in pairs(options.imports or {}) do modules[key]=value end
    helper.installImport(modules)
    package.loaded.HandlerController=nil
    return require 'HandlerController', { sliders=sliders, writes=writes, settings=settings, calls=calls, state=state,
        controller=controller, selectMask=function(id) mask=id end, setActive=function(p) active=p end,
        setSelection=function(p) selected=p end, photo=photo }
end

describe('Unified controller', function()
    it('waits for controls after loading and after asynchronous auto tone/reset', function()
        local h,s=setup({loadingTicks=2,asyncActions=true})
        assert.are.equal(0.8,h.autoTone({}).settings.Exposure2012)
        assert.are.equal(0,h.reset({}).settings.Exposure2012)
        assert.is_true(h.applySettings({settings={Contrast=12}}).success)
        assert.are.equal(12,s.settings.Contrast2012)
    end)
    it('writes a boolean false to disable Lens Blur, including delayed read-back', function()
        local h,s=setup({busyAfterWrite=true})
        s.sliders.LensBlurActive=true
        local result=h.lensBlur({active=false})
        assert.is_true(result.success)
        assert.is_false(s.sliders.LensBlurActive)
        assert.is_false(result.applied.LensBlurActive)
    end)
    it('confirms a nil Lens Blur controller value using the disabled catalog state', function()
        local h,s=setup()
        s.settings.LensBlur={}
        local get=s.controller.getValue
        s.controller.getValue=function(key) if key=='LensBlurActive' then return nil end;return get(key) end
        assert.is_true(h.lensBlur({active=false}).success)
        s.settings.LensBlur={Active=true}
        assert.is_false(h.lensBlur({active=false}).success)
    end)
    it('rejects mixed white-balance units before modifying the RAW first in selection', function()
        local h,s=setup()
        local jpeg={getDevelopSettings=function() return {IncrementalTemperature=0,IncrementalTint=0} end}
        s.setSelection({s.photo,jpeg})
        assert.has_error(function() h.batchApplySettings({settings={Temperature=6500}}) end)
        assert.are.equal(6000,s.settings.Temperature)
    end)
    it('uses incremental white-balance keys for JPEG batches', function()
        local h,s=setup()
        s.settings.Temperature=nil;s.settings.Tint=nil
        s.settings.IncrementalTemperature=0;s.settings.IncrementalTint=0
        assert.is_true(h.batchApplySettings({settings={Temperature=5,Tint=2}}).success)
        assert.are.equal(5,s.settings.IncrementalTemperature)
        assert.are.equal(2,s.settings.IncrementalTint)
        assert.are.equal('Custom',s.settings.WhiteBalance)
    end)
    it('waits for catalog persistence before allowing the next export', function()
        local h,s=setup({deferCatalogWrites=true})
        assert.is_true(h.applySettings({settings={Exposure=0.5}}).success)
        assert.are.equal(0.5,s.settings.Exposure2012)
        assert.are.equal(1,s.calls.sleeps)
    end)
    it('reports an uncommitted controller change instead of claiming success', function()
        local h,s=setup({deferCatalogWrites=true,neverCommit=true})
        local result=h.applySettings({settings={Exposure=0.5}})
        assert.is_false(result.success)
        assert.are.equal('catalog_commit',result.failures[1].parameter)
        assert.are.equal(0,s.settings.Exposure2012)
    end)
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
        assert.are.equal('completed',h.enhance({denoise=true,denoiseAmount=50}).status)
        assert.are.same({'denoise',50},s.calls[1])
        h.enhance({denoise=true})
        assert.are.equal(1,#s.calls)
        assert.is_true(s.state.denoiseState)
    end)
    it('waits for background completion after the checkbox already became enabled', function()
        local h,s=setup({enhanceTicks=5})
        local r=h.enhance({denoise=true,denoiseAmount=35})
        assert.are.equal('completed',r.status);assert.is_true(r.completion_verified)
        assert.is_false(r.state.enhanceIsRunning);assert.are.equal(35,r.state.denoiseAmount)
        assert.is_true(r.elapsed_seconds>=1.25);assert.are.equal(1,#s.calls)
    end)
    it('prefers the absolute runtime setter over a state toggle when available', function()
        local h,s=setup()
        local observed
        s.controller.setEnhance=function(name,value,amount)
            observed={name,value,amount};s.state[name .. 'State']=value
            if amount then s.state.denoiseAmount=amount end
        end
        s.controller.toggleEnhance=function() error('Must not toggle') end
        local r=h.enhance({denoise=true,denoiseAmount=37})
        assert.are.same({'denoise',true,37},observed)
        assert.is_true(r.completion_verified)
    end)
    it('does not queue a second denoise computation when the amount already matches', function()
        local h,s=setup()
        s.state.denoiseState=true;s.state.denoiseAmount=37
        s.controller.changeDenoiseAmount=function() error('Already at the requested amount') end
        local r=h.enhance({denoise=true,denoiseAmount=37})
        assert.is_true(r.completion_verified);assert.are.equal(0,#s.calls)
    end)
    it('returns an explicit timeout without resubmitting an operation that is still running', function()
        local h,s=setup({enhanceNeverFinishes=true})
        local r=h.enhance({denoise=true,timeout_seconds=1})
        assert.is_false(r.success);assert.are.equal('timeout',r.status)
        assert.is_false(r.completion_verified);assert.is_true(r.may_still_be_running)
        assert.are.equal(1,#s.calls)
    end)
    it('does not count idle as completion when Lightroom ignored the requested value', function()
        local h,s=setup({ignoreEnhance=true})
        local r=h.enhance({superRes=true,timeout_seconds=1})
        assert.is_false(r.success);assert.are.equal('timeout',r.status)
        assert.is_false(r.state.superResState);assert.are.equal(1,#s.calls)
    end)
    it('supports explicitly requesting background submission only', function()
        local h=setup({enhanceTicks=5})
        local r=h.enhance({denoise=true,wait=false})
        assert.are.equal('submitted',r.status);assert.is_false(r.completion_verified)
    end)
    it('stops polling if the active photo changes', function()
        local options={enhanceTicks=5}
        local h,s=setup(options)
        options.onSleep=function() s.setActive(nil) end
        assert.has_error(function() h.enhance({denoise=true}) end)
        assert.are.equal(1,#s.calls)
    end)
    it('does not claim completion if an older runtime exposes no completion state', function()
        local h,s=setup()
        s.photo.isAvailableForEditing=nil
        s.state.enhanceIsRunning=nil
        s.controller.toggleEnhance=function() s.state.denoiseState=true end
        local r=h.enhance({denoise=true})
        assert.are.equal('state_applied',r.status);assert.is_false(r.completion_verified)
    end)
    it('rejects invalid waits and incompatible Raw Details settings before modifying anything', function()
        local h,s=setup()
        assert.has_error(function() h.enhance({denoise=true,wait='yes'}) end)
        assert.has_error(function() h.enhance({denoise=true,timeout_seconds=0}) end)
        assert.has_error(function() h.enhance({denoise=true,rawDetails=false}) end)
        assert.are.equal(0,#s.calls)
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
        assert.is_true(s.sliders.LensBlurActive)
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
