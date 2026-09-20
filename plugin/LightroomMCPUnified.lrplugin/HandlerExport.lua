local LrApplication = import 'LrApplication'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'

local PhotoLookup = require 'PhotoLookup'
local Log = require 'Log'

local ExportHandler = {}

-- Lightroom's default collision handling is "ask", which opens a modal
-- ("The following files already exist") and blocks the export task until a
-- human clicks. Over the bridge that hangs the request until the server
-- timeout and queues every later request behind it, so re-exporting the same
-- photo to the same folder wedged the plugin. Never prompt.
local COLLISION_HANDLING = {
    rename = 'rename',
    overwrite = 'overwrite',
    skip = 'skip',
}
local DEFAULT_COLLISION_HANDLING = 'rename'

local EXPORT_FORMATS = {
    jpeg = 'JPEG',
    tiff = 'TIFF',
    original = 'ORIGINAL',
}

function ExportHandler.exportPhotos(args)
    if not args.photo_ids or #args.photo_ids == 0 then
        error("photo_ids is required")
    end

    if not args.destination then
        error("destination is required")
    end

    local catalog = LrApplication.activeCatalog()

    -- Resolve photos under read access, then RELEASE the lock before
    -- exporting. doExportOnCurrentTask() can run for minutes on a large
    -- batch; holding catalog read access for that whole span blocks every
    -- other handler (list_collections, get_selected_photos, ...) and on
    -- macOS wedged the bridge until a manual restart (issue #128).
    -- LrExportSession acquires its own catalog access during rendering, so
    -- the lock is only needed for the lookup itself.
    local photosToExport = {}
    local failures = {}
    catalog:withReadAccessDo(function()
        local resolved = PhotoLookup.resolveMany(catalog, args.photo_ids)
        for _, entry in ipairs(resolved) do
            if entry.photo then
                table.insert(photosToExport, entry.photo)
            else
                table.insert(failures, { photo_id=tostring(entry.id), error='Photo not found' })
            end
        end
    end)

    if #photosToExport == 0 then
        error("No photos found to export")
    end

    -- destinationType=specificFolder makes LR honour
    -- LR_export_destinationPathPrefix; sourceFolder ignores it and
    -- writes next to the original. LR_format is set in the
    -- format-specific block below.
    local collisionHandling = args.on_existing or DEFAULT_COLLISION_HANDLING
    if not COLLISION_HANDLING[collisionHandling] then
        error("on_existing must be one of: rename, overwrite, skip")
    end

    local exportSettings = {
        LR_export_destinationType = 'specificFolder',
        LR_export_destinationPathPrefix = args.destination,
        LR_export_useSubfolder = false,
        LR_jpeg_quality = (args.quality or 90) / 100,
        LR_collisionHandling = COLLISION_HANDLING[collisionHandling],
    }

    -- Set dimensions if specified
    if args.width or args.height then
        exportSettings.LR_size_doConstrain = true
        exportSettings.LR_size_maxWidth = args.width or args.height
        exportSettings.LR_size_maxHeight = args.height or args.width
        exportSettings.LR_size_resizeType = args.width and args.height and 'wh' or 'longEdge'
        exportSettings.LR_size_units = 'pixels'
    end

    -- Handle different formats
    local requestedFormat = args.format
    if requestedFormat ~= nil and type(requestedFormat) ~= "string" then
        error("format must be one of: jpeg, tiff, original (PNG is not a documented Lightroom export format)")
    end

    local formatKey = requestedFormat and requestedFormat:lower() or 'jpeg'
    local resolvedFormat = EXPORT_FORMATS[formatKey]
    if not resolvedFormat then
        error("format must be one of: jpeg, tiff, original (PNG is not a documented Lightroom export format)")
    end

    exportSettings.LR_format = resolvedFormat
    if resolvedFormat == 'JPEG' then
        exportSettings.LR_export_colorSpace = 'sRGB'
    elseif resolvedFormat == 'TIFF' then
        exportSettings.LR_tiff_compressionMethod = 'compressionMethod_LZW'
    end

    -- Lightroom requires the target directory to exist before session creation.
    local created, createError = LrFileUtils.createAllDirectories(args.destination)
    if not created then error('Cannot create export destination: ' .. tostring(createError)) end

    -- Create export session
    local exportSession = LrExportSession {
        photosToExport = photosToExport,
        exportSettings = exportSettings,
    }

    -- Execute export (outside the read-access block above)
    local exportedCount, paths = 0, {}
    -- Existing-file skip may remove renditions before iteration starts.
    local plannedRenditions=exportSession:countRenditions()
    local skippedCount=collisionHandling=='skip' and math.max(0,#photosToExport-plannedRenditions) or 0
    for _, rendition in exportSession:renditions({ stopIfCanceled=true }) do
        local ok, pathOrError = rendition:waitForRender()
        if rendition.wasSkipped then
            skippedCount=skippedCount+1
        elseif ok then
            exportedCount = exportedCount + 1
            table.insert(paths, pathOrError)
        else
            table.insert(failures, { error=tostring(pathOrError) })
        end
    end
    if exportedCount + skippedCount + #failures < #args.photo_ids then
        table.insert(failures, { error='Some renditions were skipped or cancelled' })
    end

    Log.info(string.format("Exported %d photos to: %s", exportedCount, args.destination))

    return {
        success = #failures == 0,
        exported = exportedCount,
        skipped = skippedCount,
        destination = args.destination,
        paths = paths,
        failures = failures,
        message = string.format("Exported %d photos to %s", exportedCount, args.destination)
    }
end

return ExportHandler
