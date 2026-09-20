local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'

local Log = require 'Log'
local CollectionLookup = require 'CollectionLookup'

local ImportHandler = {}

function ImportHandler.importPhotos(args)
    if not args.source_path then
        error("source_path is required")
    end

    -- LrFileUtils.exists returns 'file' / 'directory' / false. Use it for the
    -- directory check too: LrFileUtils.isDirectory is absent on some Lightroom
    -- Classic runtimes (nil there, e.g. 15.3.1 -- issue #129), whereas exists
    -- is stable across supported versions.
    local sourceKind = LrFileUtils.exists(args.source_path)
    if not sourceKind then
        error("Source path does not exist: " .. args.source_path)
    end

    local catalog = LrApplication.activeCatalog()
    local importedCount = 0

    -- Enumerate source files OUTSIDE any catalog lock; the filesystem walk
    -- needs no catalog access.
    local photosToImport = {}
    if sourceKind == 'directory' then
        -- Import all photos from directory, including nested subfolders.
        -- LrFileUtils.files lists only the immediate directory, so a source
        -- organized as shoot/roll subfolders (the common Lightroom layout)
        -- enumerated nothing and failed with "No photos found to import".
        for file in LrFileUtils.recursiveFiles(args.source_path) do
            -- extension() is on LrPathUtils; LrFileUtils has no such field, so
            -- the previous call was nil and raised "attempt to call field
            -- 'extension' (a nil value)" on every directory import.
            local ext = LrPathUtils.extension(file):lower()
            if ext == 'jpg' or ext == 'jpeg' or ext == 'png' or
               ext == 'tif' or ext == 'tiff' or ext == 'dng' or
               ext == 'cr2' or ext == 'nef' or ext == 'arw' then
                table.insert(photosToImport, file)
            end
        end
    else
        -- Import single photo
        table.insert(photosToImport, args.source_path)
    end

    if #photosToImport == 0 then
        error("No photos found to import")
    end

    -- Resolve the collection before importing anything; reject ambiguous names.
    local targetCollection = args.collection_name and CollectionLookup.find(catalog, args.collection_name, false) or nil
    if args.collection_name and not targetCollection then error('Collection not found: ' .. args.collection_name) end
    -- copy_to is the public MCP contract; destination remains a legacy TCP alias.
    local copyTo = args.copy_to or args.destination
    local planned = {}
    local destinations = {}
    for _, filePath in ipairs(photosToImport) do
        local destination = filePath
        if copyTo then
            destination = LrPathUtils.child(copyTo, LrPathUtils.leafName(filePath))
            local folded = destination:lower()
            if destinations[folded] or LrFileUtils.exists(destination) then
                error('Import destination collision; no files copied: ' .. destination)
            end
            destinations[folded] = true
        end
        planned[#planned+1] = { source=filePath, destination=destination }
    end
    if copyTo then
        local created, err=LrFileUtils.createAllDirectories(copyTo)
        if not created then error('Cannot create import destination: ' .. tostring(err)) end
    end

    local results, failures, addedPhotos = {}, {}, {}
    for _, item in ipairs(planned) do
        local copied = false
        local ok, err=LrTasks.pcall(function()
            if copyTo then
                local copyOK, copyErr=LrFileUtils.copy(item.source, item.destination)
                if not copyOK then error('Copy failed: ' .. tostring(copyErr)) end
                copied = true
            end
            catalog:withWriteAccessDo('MCP Unified: import photo', function()
                local photo=catalog:addPhoto(item.destination)
                if not photo then error('Lightroom did not add this photo (it may already be in the catalog)') end
                addedPhotos[#addedPhotos+1]=photo
                importedCount=importedCount+1
            end, { timeout=30 })
        end)
        local result={ source=item.source, path=item.destination, copied=copied, success=ok, error=not ok and tostring(err) or nil }
        results[#results+1]=result
        if not ok then failures[#failures+1]=result end
    end
    if targetCollection and #addedPhotos > 0 then
        local ok, err=LrTasks.pcall(function()
            catalog:withWriteAccessDo('MCP Unified: collect imports', function()
                targetCollection:addPhotos(addedPhotos)
            end, { timeout=30 })
        end)
        if not ok then failures[#failures+1]={ collection=args.collection_name, error=tostring(err) } end
    end

    Log.info(string.format("Imported %d photos from: %s", importedCount, args.source_path))

    return {
        success = #failures == 0,
        imported = importedCount,
        photos = results,
        failures = failures,
        atomic = false,
        message = string.format("Imported %d photos", importedCount)
    }
end

return ImportHandler
