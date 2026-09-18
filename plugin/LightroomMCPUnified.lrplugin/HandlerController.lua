-- Independently implemented against Adobe Lightroom Classic 15 SDK APIs.
local App = import 'LrApplication'
local View = import 'LrApplicationView'
local DC = import 'LrDevelopController'
local Tasks = import 'LrTasks'
local Parameters = require 'DevelopParameters'
local H = {}

local function api(name)
    if type(DC[name]) ~= 'function' then
        error('Unsupported Lightroom runtime API: LrDevelopController.' .. name)
    end
    return DC[name]
end

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
    return photo, catalog
end

local function guard(photo)
    local current = App.activeCatalog():getTargetPhoto()
    if not current or current.localIdentifier ~= photo.localIdentifier then error('Active photo changed; operation stopped') end
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
        if ok and type(value) == 'number' then values[key] = value end
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
            local actual = api('getValue')(key)
            if type(actual) ~= 'number' or math.abs(actual - values[key]) > 0.001 then
                error('Read-back did not match requested value')
            end
            return actual
        end)
        if ok then applied[key] = value
        else
            failures[#failures+1] = { parameter=key, error=tostring(value) }
            break -- do not continue editing after selection or SDK errors
        end
    end
    return { success=#failures == 0, photo_id=tostring(photo.localIdentifier), applied=applied, failures=failures, atomic=false }
end

function H.ping(_args)
    return { pong=true, version=App.versionString(), plugin_version='0.1.0' }
end

function H.capabilities(_args)
    local names = { 'getValue', 'getRange', 'setValue', 'setAutoTone', 'resetAllDevelopAdjustments', 'createNewMask', 'getSelectedMask', 'getAllMasks', 'setLensBlurBokeh', 'getSelectedLensBlurBokeh', 'toggleEnhance', 'getEnhancePanelState', 'changeDenoiseAmount' }
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
    local sourceRawWB = type(sourceSettings.Temperature) == "number" and sourceSettings.Temperature >= 1000
    local results, changed = {}, 0
    for _, item in ipairs(selected) do
        local ok, err = Tasks.pcall(function()
            local current = item:getDevelopSettings()
            local update = {}
            for _, key in ipairs(keys) do
                local sdkKey = Parameters.catalogAliases[key] or key
                if current[sdkKey] == nil then error('Catalog setting unavailable on this photo: ' .. sdkKey) end
                if (key == 'Temperature' or key == 'Tint') and (type(current.Temperature) ~= 'number' or (current.Temperature >= 1000) ~= sourceRawWB) then
                    error('White-balance units differ; separate RAW and rendered files into different batches')
                end
                update[sdkKey] = values[key]
            end
            catalog:withWriteAccessDo('MCP Unified: batch develop', function() item:applyDevelopSettings(update) end, { timeout=30 })
        end)
        if ok then changed=changed+1 end
        results[#results+1] = { photo_id=tostring(item.localIdentifier), success=ok, error=not ok and tostring(err) or nil }
    end
    return { success=changed == #selected, applied=changed, total=#selected, photos=results, atomic=false }
end

function H.autoTone(args)
    local photo = activePhoto(args, true)
    api('setAutoTone')()
    return { success=true, photo_id=tostring(photo.localIdentifier), settings=photo:getDevelopSettings() }
end

function H.reset(args)
    local photo = activePhoto(args, true)
    api('resetAllDevelopAdjustments')()
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
            next_step='Finish drawing, sampling or choosing the mask in Lightroom, then call lr_update_mask with the adjustments.' }
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
    if args.focalRangeFromSubject then error('focalRangeFromSubject is not documented by the Lightroom 15 SDK; set the focal range in Lightroom') end
    if args.bokeh then api('setLensBlurBokeh'); api('getSelectedLensBlurBokeh') end
    local requested, keys = { LensBlurActive=args.active == false and 0 or 1 }, { 'LensBlurActive' }
    for option, param in pairs({ amount='LensBlurAmount', catEye='LensBlurCatEye', highlightsBoost='LensBlurHighlightsBoost' }) do
        if args[option] ~= nil then requested[param]=args[option]; keys[#keys+1]=param end
    end
    for _, key in ipairs(keys) do
        local lo, hi=api('getRange')(key)
        if type(lo) ~= 'number' or type(hi) ~= 'number' then error('Lens Blur slider unsupported for this image: ' .. key) end
        if requested[key] < lo or requested[key] > hi then error('Out-of-range Lens Blur value: ' .. key) end
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
    local photo = activePhoto(args, true)
    api('toggleEnhance'); api('getEnhancePanelState')
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
    if #operations == 1 then
        local feature=operations[1]
        if args.denoiseAmount and feature ~= 'denoise' then error('denoiseAmount may only accompany a denoise operation') end
        guard(photo)
        DC.toggleEnhance(feature, args.denoiseAmount)
    elseif args.denoiseAmount then
        if state.denoiseState ~= true then error('Enable denoise=true before adjusting its strength') end
        api('changeDenoiseAmount')(args.denoiseAmount)
    elseif args.denoise == nil and args.rawDetails == nil and args.superRes == nil then error('At least one Enhance option is required') end
    return { success=true, status=#operations > 0 and 'submitted' or 'state_checked', photo_id=tostring(photo.localIdentifier), state=DC.getEnhancePanelState(), completion_verified=false }
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
