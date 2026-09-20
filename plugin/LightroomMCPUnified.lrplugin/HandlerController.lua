-- Independently implemented against Adobe Lightroom Classic 15 SDK APIs.
local App = import 'LrApplication'
local View = import 'LrApplicationView'
local DC = import 'LrDevelopController'
local Tasks = import 'LrTasks'
local Date = import 'LrDate'
local Parameters = require 'DevelopParameters'
local H = {}

local function api(name)
    if type(DC[name]) ~= 'function' then
        error('Unsupported Lightroom runtime API: LrDevelopController.' .. name)
    end
    return DC[name]
end

local waitForDevelop
local function activePhoto(args, develop)
    local catalog = App.activeCatalog()
    local photo = catalog:getTargetPhoto()
    if not photo then error('Select a photo in Lightroom first') end
    local id = tostring(photo.localIdentifier)
    if args.photo_id and tostring(args.photo_id) ~= id then error('Active photo changed; expected ' .. tostring(args.photo_id) .. ', found ' .. id) end
    if develop and View.getCurrentModuleName() ~= 'develop' then
        View.switchToModule('develop')
        for _ = 1, 50 do
            if View.getCurrentModuleName() == 'develop' then break end
            Tasks.sleep(0.1)
        end
        if View.getCurrentModuleName() ~= 'develop' then error('Could not activate Develop module') end
    end
    local current = catalog:getTargetPhoto()
    if not current or tostring(current.localIdentifier) ~= id then error('Active photo changed during operation') end
    if develop then waitForDevelop(photo) end
    return photo, catalog
end

local function guard(photo)
    local current = App.activeCatalog():getTargetPhoto()
    if not current or current.localIdentifier ~= photo.localIdentifier then error('Active photo changed; operation stopped') end
end

waitForDevelop = function(photo)
    for attempt=1,201 do
        guard(photo)
        local ok, ready=Tasks.pcall(function()
            if type(photo.isAvailableForEditing)=='function' and not photo:isAvailableForEditing() then return false end
            local exposure=api('getValue')('Exposure')
            local lo,hi=api('getRange')('Contrast')
            return type(exposure)=='number' and type(lo)=='number' and type(hi)=='number'
        end)
        if ok and ready then return end
        if attempt < 201 then Tasks.sleep(0.1) end
    end
    error('Lightroom Develop controls are still loading or the photo is locked by a background operation; wait and re-read its state before retrying')
end

local function valueMatches(actual, requested)
    if type(requested)=='boolean' then return type(actual)=='boolean' and actual==requested end
    return type(actual)=='number' and math.abs(actual-requested)<=0.001
end

local function catalogKeyFor(settings, key)
    local mapped=Parameters.catalogAliases[key] or key
    if (key=='Temperature' or key=='Tint') and settings[mapped]==nil then mapped='Incremental' .. key end
    return mapped
end

local function index(names, localMode)
    local out = {}
    for _, name in ipairs(names) do
        out[name:lower()] = name
        if localMode then out[name:sub(7):lower()] = name end
    end
    if localMode then
        out.moirefilter = 'local_Moire'
    else
        for ui, catalogKey in pairs(Parameters.catalogAliases) do out[catalogKey:lower()] = ui end
    end
    return out
end
local globalIndex = index(Parameters.global, false)
local localIndex = index(Parameters.localAdjustments, true)

local function valuesAndRanges(names)
    local values, ranges = {}, {}
    for _, key in ipairs(names) do
        local ok, value = Tasks.pcall(function() return api('getValue')(key) end)
        local rangeOK, lo, hi = Tasks.pcall(function() return api('getRange')(key) end)
        if ok and (type(value) == 'number' or type(value) == 'boolean' or type(value) == 'table') then values[key] = value end
        if rangeOK and type(lo) == 'number' and type(hi) == 'number' then ranges[key] = { min=lo, max=hi } end
    end
    return values, ranges
end

local function normalize(settings, localMode, namesOnly)
    if type(settings) ~= 'table' or next(settings) == nil then error('A nonempty settings object is required') end
    local names = localMode and localIndex or globalIndex
    local normalized, keys = {}, {}
    for raw, value in pairs(settings) do
        local key = type(raw) == 'string' and names[raw:lower()]
        if not key then error('Unsupported ' .. (localMode and 'local' or 'global') .. ' slider: ' .. tostring(raw)) end
        if normalized[key] ~= nil then error('Duplicate aliases for slider ' .. key) end
        if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then error('Finite numeric value required: ' .. key) end
        local ok, lo, hi = true, -math.huge, math.huge
        if not namesOnly then ok, lo, hi = Tasks.pcall(function() return api('getRange')(key) end) end
        if not ok or type(lo) ~= 'number' or type(hi) ~= 'number' then error('Slider unavailable for this image: ' .. key) end
        if value < lo or value > hi then error(key .. ' must be in [' .. tostring(lo) .. ', ' .. tostring(hi) .. '] for this image') end
        normalized[key] = value
        keys[#keys+1] = key
    end
    table.sort(keys)
    return normalized, keys
end

local function writeSliders(photo, values, keys, maskID)
    local applied, failures = {}, {}
    for _, key in ipairs(keys) do
        local ok, value = Tasks.pcall(function()
            guard(photo)
            if maskID and api('getSelectedMask')() ~= maskID then error('Selected mask changed') end
            api('setValue')(key, values[key])
            local actual
            for attempt=1,51 do
                guard(photo)
                if maskID and api('getSelectedMask')()~=maskID then error('Selected mask changed') end
                actual=api('getValue')(key)
                if key=='LensBlurActive' and actual==nil and values[key]==false then
                    -- Disabled Lens Blur returns nil from the controller in 15.5.1.
                    -- Confirm the disabled state in the catalog instead of treating
                    -- any transient nil as a successful write.
                    local blur=photo:getDevelopSettings().LensBlur
                    if type(blur)=='table' and blur.Active~=true then actual=false end
                end
                if valueMatches(actual,values[key]) then break end
                -- nil means the controller is temporarily rebuilding after an edit.
                if actual~=nil or attempt==51 then break end
                Tasks.sleep(0.1)
            end
            if not valueMatches(actual, values[key]) then
                error('Read-back did not match requested value: requested=' .. tostring(values[key]) .. ', actual=' .. tostring(actual) .. ' (' .. type(actual) .. ')')
            end
            return actual
        end)
        if ok then applied[key] = value
        else
            failures[#failures+1] = { parameter=key, error=tostring(value) }
            break -- do not continue editing after selection or SDK errors
        end
    end
    if next(applied) then
        local ok, err = Tasks.pcall(function()
            guard(photo)
            if type(DC.stopTracking) == 'function' then DC.stopTracking(maskID ~= nil) end
            -- Controller values update before the catalog commits them. An export
            -- started in that gap can render the previous edit (observed in 15.5.1).
            if not maskID then
                local expected = {}
                local current = photo:getDevelopSettings()
                for key, value in pairs(applied) do
                    local catalogKey = catalogKeyFor(current,key)
                    if type(current[catalogKey]) == 'number' then expected[catalogKey] = value end
                end
                for attempt = 1, 51 do
                    guard(photo)
                    current = photo:getDevelopSettings()
                    local ready = true
                    for key, value in pairs(expected) do
                        if type(current[key]) ~= 'number' or math.abs(current[key] - value) > 0.001 then ready = false end
                    end
                    if ready then return end
                    if attempt == 51 then error('Catalog did not commit the requested slider values; read state before retrying') end
                    Tasks.sleep(0.1)
                end
            end
        end)
        if not ok then failures[#failures+1] = { parameter='catalog_commit', error=tostring(err) } end
    end
    return { success=#failures == 0, photo_id=tostring(photo.localIdentifier), applied=applied, failures=failures, atomic=false }
end

function H.ping(_args)
    return { pong=true, version=App.versionString(), plugin_version='0.1.0' }
end

function H.capabilities(_args)
    local names = { 'getValue', 'getRange', 'setValue', 'setAutoTone', 'resetAllDevelopAdjustments', 'createNewMask', 'getSelectedMask', 'getAllMasks', 'setLensBlurBokeh', 'getSelectedLensBlurBokeh', 'setEnhance', 'toggleEnhance', 'getEnhancePanelState', 'changeDenoiseAmount' }
    local methods = {}
    for _, name in ipairs(names) do methods[name] = type(DC[name]) == 'function' end
    return {
        version=App.versionString(), sdk_target='15.0', methods=methods,
        global_parameters=Parameters.global, local_parameters=Parameters.localAdjustments,
        focal_range_from_subject=false, mask_geometry=false,
        notes={ 'API presence does not guarantee GPU/image eligibility.', 'Manual/range/object/people masks can require UI interaction.', 'Latest Adobe download could not be verified without Adobe Developer sign-in.' },
    }
end

function H.getSettings(args)
    local photo = activePhoto(args, true)
    local values, ranges = valuesAndRanges(Parameters.global)
    local result = { photo_id=tostring(photo.localIdentifier), filename=photo:getFormattedMetadata('fileName'), rating=photo:getRawMetadata('rating'), settings=photo:getDevelopSettings(), sliders=values, ranges=ranges }
    if type(DC.getEnhancePanelState) == 'function' then result.enhance = DC.getEnhancePanelState() end
    local blur, blurRanges=valuesAndRanges({ 'LensBlurActive', 'LensBlurAmount', 'LensBlurCatEye', 'LensBlurHighlightsBoost', 'LensBlurFocalRange' })
    if blur.LensBlurActive==nil and type(result.settings.LensBlur)=='table' and result.settings.LensBlur.Active~=true then blur.LensBlurActive=false end
    result.lens_blur={ values=blur, ranges=blurRanges }
    result.runtime={ module=View.getCurrentModuleName(), setEnhance=type(DC.setEnhance)=='function', isAvailableForEditing=type(photo.isAvailableForEditing)=='function' }
    if type(photo.isAvailableForEditing)=='function' then result.runtime.available_for_editing=photo:isAvailableForEditing() end
    return result
end

function H.applySettings(args)
    local photo = activePhoto(args, true)
    local values, keys = normalize(args.settings, false)
    return writeSliders(photo, values, keys)
end

function H.batchApplySettings(args)
    local photo, catalog = activePhoto(args, true)
    local values, keys = normalize(args.settings, false)
    guard(photo)
    local selected = catalog:getTargetPhotos()
    if #selected == 0 then error('No explicit photo selection') end
    if #selected > 1000 then error('Select at most 1000 photos per batch') end
    local sourceSettings = photo:getDevelopSettings()
    local sourceRawWB = type(sourceSettings.Temperature) == 'number'
    local planned = {}
    -- Preflight the entire selection before changing even the first photo.
    for _, item in ipairs(selected) do
        local current=item:getDevelopSettings()
        local update={}
        for _, key in ipairs(keys) do
            if (key=='Temperature' or key=='Tint') and (type(current.Temperature)=='number')~=sourceRawWB then
                error('White-balance units differ; separate RAW and rendered files into different batches')
            end
            local sdkKey=catalogKeyFor(current,key)
            if current[sdkKey]==nil then error('Catalog setting unavailable on this photo: ' .. sdkKey) end
            update[sdkKey]=values[key]
            if key=='Temperature' or key=='Tint' then update.WhiteBalance='Custom' end
        end
        planned[#planned+1]={photo=item,settings=update}
    end
    local results, changed = {}, 0
    for _, item in ipairs(planned) do
        local ok, err = Tasks.pcall(function()
            guard(photo)
            catalog:withWriteAccessDo('MCP Unified: batch develop', function() item.photo:applyDevelopSettings(item.settings) end, { timeout=30 })
            local actual=item.photo:getDevelopSettings()
            for key,value in pairs(item.settings) do
                if type(value)=='number' and not valueMatches(actual[key],value) then error('Catalog read-back did not match ' .. key) end
                if type(value)=='string' and actual[key]~=value then error('Catalog read-back did not match ' .. key) end
            end
        end)
        if ok then changed=changed+1 end
        results[#results+1] = { photo_id=tostring(item.photo.localIdentifier), success=ok, error=not ok and tostring(err) or nil }
    end
    return { success=changed == #selected, applied=changed, total=#selected, photos=results, atomic=false }
end

function H.autoTone(args)
    local photo = activePhoto(args, true)
    api('setAutoTone')()
    Tasks.sleep(0.1)
    waitForDevelop(photo)
    if type(DC.stopTracking)=='function' then DC.stopTracking() end
    return { success=true, photo_id=tostring(photo.localIdentifier), settings=photo:getDevelopSettings() }
end

function H.reset(args)
    local photo = activePhoto(args, true)
    api('resetAllDevelopAdjustments')()
    Tasks.sleep(0.1)
    waitForDevelop(photo)
    return { success=true, photo_id=tostring(photo.localIdentifier), settings=photo:getDevelopSettings() }
end

function H.crop(args)
    local photo, catalog = activePhoto(args, false)
    local current = photo:getDevelopSettings()
    local rect, changed = {}, false
    for key, fallback in pairs({ CropTop=0, CropLeft=0, CropBottom=1, CropRight=1 }) do
        rect[key] = args[key] ~= nil and args[key] or current[key] or fallback
        if type(rect[key]) ~= 'number' or rect[key] < 0 or rect[key] > 1 then error('Invalid crop boundary: ' .. key) end
        if args[key] ~= nil then changed=true end
    end
    if rect.CropTop >= rect.CropBottom or rect.CropLeft >= rect.CropRight then error('Crop rectangle must have positive width and height') end
    if args.angle ~= nil then
        if type(args.angle) ~= 'number' or args.angle < -45 or args.angle > 45 then error('angle must be in [-45,45]') end
        rect.CropAngle=args.angle; changed=true
    end
    if not changed then error('At least one crop boundary or angle is required') end
    rect.HasCrop=true
    catalog:withWriteAccessDo('MCP Unified: crop', function() photo:applyDevelopSettings(rect) end, { timeout=30 })
    return { success=true, photo_id=tostring(photo.localIdentifier), crop=rect }
end

local function selectedMask()
    api('goToMasking')()
    local id = api('getSelectedMask')()
    if type(id) ~= 'string' or id == '' then error('Select a mask in Lightroom first') end
    return id
end

function H.updateMask(args)
    local photo = activePhoto(args, true)
    local id = selectedMask()
    local values, keys = normalize(args.adjustments, true)
    local result = writeSliders(photo, values, keys, id)
    result.mask_id = id
    return result
end

function H.addMask(args)
    local photo = activePhoto(args, true)
    if args.params and next(args.params) then error('Mask geometry parameters are not exposed by createNewMask') end
    local types = {
        subject={'aiSelection','subject'}, sky={'aiSelection','sky'}, background={'aiSelection','background'},
        objects={'aiSelection','objects'}, people={'aiSelection','people'}, landscape={'aiSelection','landscape'},
        luminance={'rangeMask','luminance'}, color={'rangeMask','color'}, depth={'rangeMask','depth'},
        gradient={'gradient'}, radialGradient={'radialGradient'}, brush={'brush'},
    }
    local spec = types[args.maskType]
    if not spec then error('Unsupported mask type') end
    api('createNewMask'); api('getSelectedMask'); api('goToMasking')()
    -- Validate local names/values before creating anything.
    local values, keys
    if args.adjustments then values, keys = normalize(args.adjustments, true, true) end
    local previous = DC.getSelectedMask()
    DC.createNewMask(spec[1], spec[2])
    local automatic = args.maskType == 'subject' or args.maskType == 'sky' or args.maskType == 'background'
    if not automatic then
        return { success=true, status='requires_user_interaction', photo_id=tostring(photo.localIdentifier), adjustments_applied=false,
            next_step=args.maskType=='objects'
                and 'Use Brush Select or Rectangle Select to indicate the target object in Lightroom. Lightroom then detects its edges automatically. After detection, call lr_update_mask.'
                or 'Finish drawing, sampling or choosing the mask in Lightroom, then call lr_update_mask with the adjustments.' }
    end
    local id
    for _ = 1, 100 do
        guard(photo)
        id = DC.getSelectedMask()
        if type(id) == 'string' and id ~= '' and id ~= previous then break end
        Tasks.sleep(0.1)
    end
    if type(id) ~= 'string' or id == '' or id == previous then
        return { success=true, status='pending', adjustments_applied=false, next_step='Wait for Lightroom to finish generating the mask, select it, then call lr_update_mask.' }
    end
    if values then values, keys = normalize(args.adjustments, true) end
    local result = values and writeSliders(photo, values, keys, id) or { success=true, photo_id=tostring(photo.localIdentifier) }
    result.mask_id=id; result.status='mask_selected'; result.adjustments_applied=values ~= nil and result.success
    return result
end

function H.lensBlur(args)
    local photo = activePhoto(args, true)
    api('getSelectedLensBlurBokeh')
    if args.focalRangeFromSubject then error('focalRangeFromSubject is not documented by the Lightroom 15 SDK; set the focal range in Lightroom') end
    if args.bokeh then api('setLensBlurBokeh'); api('getSelectedLensBlurBokeh') end
    -- This is a boolean SDK value. In Lua, numeric 0 is truthy and enables blur.
    local requested, keys = { LensBlurActive=args.active ~= false }, { 'LensBlurActive' }
    for option, param in pairs({ amount='LensBlurAmount', catEye='LensBlurCatEye', highlightsBoost='LensBlurHighlightsBoost' }) do
        if args[option] ~= nil then requested[param]=args[option]; keys[#keys+1]=param end
    end
    for _, key in ipairs(keys) do
        if key~='LensBlurActive' then
            local lo, hi=api('getRange')(key)
            if type(lo) ~= 'number' or type(hi) ~= 'number' then error('Lens Blur slider unsupported for this image: ' .. key) end
            if requested[key] < lo or requested[key] > hi then error('Out-of-range Lens Blur value: ' .. key) end
        end
    end
    local result=writeSliders(photo, requested, keys)
    if result.success and args.bokeh then
        local ok, err=Tasks.pcall(function()
            guard(photo); DC.setLensBlurBokeh(args.bokeh)
            if DC.getSelectedLensBlurBokeh() ~= args.bokeh then error('Bokeh read-back mismatch') end
        end)
        if not ok then result.success=false; result.failures[#result.failures+1]={ parameter='bokeh', error=tostring(err) }
        else result.bokeh=args.bokeh end
    end
    result.render_complete=false
    return result
end

function H.enhance(args)
    local wait=args.wait~=false
    local timeout=args.timeout_seconds or 120
    if args.wait~=nil and type(args.wait)~='boolean' then error('wait must be boolean') end
    if type(timeout)~='number' or timeout<1 or timeout>240 or timeout~=math.floor(timeout) then error('timeout_seconds must be an integer from 1 to 240') end
    if args.rawDetails==false and (args.denoise==true or args.superRes==true) then error('Denoise and Super Resolution require Raw Details; rawDetails=false conflicts with this request') end
    local photo = activePhoto(args, true)
    if type(DC.setEnhance)~='function' then api('toggleEnhance') end
    api('getEnhancePanelState')
    local state=DC.getEnhancePanelState()
    if state.enhanceIsRunning then error('Lightroom Enhance is already running; inspect lr_get_settings before retrying') end
    local operations={}
    for _, feature in ipairs({ 'denoise', 'rawDetails', 'superRes' }) do
        if args[feature] ~= nil then
            if type(args[feature]) ~= 'boolean' then error(feature .. ' must be boolean') end
            if state[feature .. 'State'] ~= args[feature] then
                if state[feature .. 'Enabled'] ~= true then error(feature .. ' is disabled for this image') end
                operations[#operations+1]=feature
            end
        end
    end
    if #operations > 1 then error('Change one Enhance feature per call; re-read state before the next operation') end
    if args.denoiseAmount ~= nil and (args.denoiseAmount < 1 or args.denoiseAmount > 100) then error('denoiseAmount must be in [1,100]') end
    if args.denoiseAmount and args.denoise == false then error('denoiseAmount cannot accompany denoise=false') end
    local submitted=false
    if #operations == 1 then
        local feature=operations[1]
        if args.denoiseAmount and feature ~= 'denoise' then error('denoiseAmount may only accompany a denoise operation') end
        guard(photo)
        if type(DC.setEnhance)=='function' then DC.setEnhance(feature,args[feature],args.denoiseAmount)
        else DC.toggleEnhance(feature, args.denoiseAmount) end
        submitted=true
    elseif args.denoiseAmount then
        if state.denoiseState ~= true then error('Enable denoise=true before adjusting its strength') end
        if state.denoiseAmount~=args.denoiseAmount then
            api('changeDenoiseAmount')(args.denoiseAmount)
            submitted=true
        end
    elseif args.denoise == nil and args.rawDetails == nil and args.superRes == nil then error('At least one Enhance option is required') end
    if not wait then
        return { success=true, status=submitted and 'submitted' or 'state_checked', photo_id=tostring(photo.localIdentifier), state=DC.getEnhancePanelState(), completion_verified=false }
    end

    -- Poll cooperatively in this one MCP call. An enabled checkbox alone does
    -- not prove the background render finished. 15.5.1 can omit enhanceIsRunning,
    -- so use the per-photo editing lock when that runtime API is available.
    local started=Date.currentTime()
    local hasEditingState=type(photo.isAvailableForEditing)=='function'
    local stable=0
    local lastState=state
    repeat
        guard(photo)
        local ok, snapshot=Tasks.pcall(function()
            local current=DC.getEnhancePanelState()
            local editable=not hasEditingState or photo:isAvailableForEditing()
            local known=hasEditingState or type(current.enhanceIsRunning)=='boolean'
            local matches=true
            for _, feature in ipairs({'denoise','rawDetails','superRes'}) do
                if args[feature]~=nil and current[feature .. 'State']~=args[feature] then matches=false end
            end
            if args.denoiseAmount~=nil and (type(current.denoiseAmount)~='number' or math.abs(current.denoiseAmount-args.denoiseAmount)>0.001) then matches=false end
            return {state=current,known=known,matches=matches,
                ready=editable and current.enhanceIsRunning~=true and current.enhanceNeedsUpdate~=true
                    and type(DC.getValue('Exposure'))=='number'}
        end)
        guard(photo)
        if ok then
            lastState=snapshot.state
            if snapshot.matches and not snapshot.known then
                return { success=true,status='state_applied',photo_id=tostring(photo.localIdentifier),state=lastState,
                    completion_verified=false,reason='This Lightroom runtime exposes no usable background completion state' }
            end
            if snapshot.matches and snapshot.ready and snapshot.known then stable=stable+1 else stable=0 end
            if stable>=2 then
                return {success=true,status='completed',photo_id=tostring(photo.localIdentifier),state=lastState,
                    completion_verified=true,elapsed_seconds=Date.currentTime()-started}
            end
        else stable=0 end
        if Date.currentTime()-started>=timeout then break end
        Tasks.sleep(0.25)
    until false
    return {success=false,status='timeout',photo_id=tostring(photo.localIdentifier),state=lastState,
        completion_verified=false,may_still_be_running=true,elapsed_seconds=Date.currentTime()-started,
        next_step='The wait timed out; Lightroom may still be processing. Read its state before retrying. No second toggle was sent.'}
end

function H.exportPreview(args)
    local photo = activePhoto(args, false)
    local size=args.size or 1500
    if type(size) ~= 'number' or size < 64 or size > 2048 or size ~= math.floor(size) then error('Preview size must be an integer from 64 to 2048') end
    local Export=import 'LrExportSession'
    local Files=import 'LrFileUtils'
    local Paths=import 'LrPathUtils'
    local UUID=import 'LrUUID'
    local Strings=import 'LrStringUtils'
    local folder=Paths.child(Paths.getStandardFilePath('temp'), 'lightroom-mcp-unified-' .. UUID.generateUUID())
    Files.createAllDirectories(folder)
    local ok, result=Tasks.pcall(function()
        local session=Export { photosToExport={ photo }, exportSettings={
            LR_export_destinationType='specificFolder', LR_export_destinationPathPrefix=folder,
            LR_export_useSubfolder=false, LR_collisionHandling='rename', LR_format='JPEG',
            LR_export_colorSpace='sRGB', LR_jpeg_quality=0.85,
            LR_size_doConstrain=true, LR_size_doNotEnlarge=true, LR_size_resizeType='longEdge',
            LR_size_maxHeight=size, LR_size_maxWidth=size, LR_size_units='pixels',
            LR_minimizeEmbeddedMetadata=true, LR_removeLocationMetadata=true,
        } }
        for _, rendition in session:renditions({ stopIfCanceled=true }) do
            local rendered, pathOrError=rendition:waitForRender()
            if not rendered then error('Preview render failed: ' .. tostring(pathOrError)) end
            local f, err=io.open(pathOrError,'rb')
            if not f then error('Could not open rendered JPEG: ' .. tostring(err)) end
            local data=f:read(8*1024*1024+1); f:close()
            if not data or #data > 8*1024*1024 then error('Preview exceeds 8 MiB; request a smaller size') end
            if data:sub(1,3) ~= string.char(255,216,255) then error('Renderer did not return a JPEG') end
            return { success=true, photo_id=tostring(photo.localIdentifier), mime_type='image/jpeg', image_base64=Strings.encodeBase64(data), size=size }
        end
        error('Lightroom returned no preview rendition')
    end)
    local cleaned=Files.delete(folder)
    if not ok then error(result) end
    if cleaned == false then result.cleanup_warning='Lightroom could not remove its temporary preview folder' end
    return result
end

return H
