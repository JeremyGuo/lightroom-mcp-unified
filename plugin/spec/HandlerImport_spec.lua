local helper = require 'spec_helper'

-- Mirrors the real SDK: LrFileUtils.exists returns 'file' / 'directory' / false,
-- and LrFileUtils.isDirectory is intentionally absent (nil on some Lightroom
-- Classic runtimes -- issue #129).
--
-- Two omissions here are deliberate and load-bearing:
--   * no `extension` -- that field lives on LrPathUtils, not LrFileUtils.
--   * no `files`     -- the handler must walk nested subfolders via
--                       recursiveFiles; a plain files() walk misses them.
-- Providing either would let a regression to the wrong API pass green, which
-- is precisely how both bugs shipped.
local function fakeFileUtils(opts)
    return {
        exists = function(p)
            if opts.directories and opts.directories[p] then return 'directory' end
            if opts.exists and opts.exists[p] then return 'file' end
            return false
        end,
        createAllDirectories = function() return true end,
        copy = function(src,dest)
            opts.copies = opts.copies or {}; opts.copies[#opts.copies+1] = {src,dest}
            if opts.copyError then return false, opts.copyError end
            return true
        end,
        recursiveFiles = function(_)
            local i = 0
            local list = opts.dirContents or {}
            return function()
                i = i + 1
                return list[i]
            end
        end,
    }
end

-- extension() belongs to LrPathUtils in the real SDK.
local function fakePathUtils()
    return {
        extension = function(p) return p:match("%.([^.]+)$") or "" end,
        leafName = function(p) return p:match('[^/]+$') end,
        child = function(a,b) return a .. '/' .. b end,
    }
end

local function setup(opts)
    local catalog = helper.fakeCatalog({ collections = opts.collections or {} })
    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrTasks = { pcall=pcall },
        LrFileUtils = fakeFileUtils(opts.fs or {}),
        LrPathUtils = fakePathUtils(),
    })
    package.loaded.HandlerImport = nil
    return catalog, require 'HandlerImport'
end

describe("HandlerImport.importPhotos", function()
    it("imports a single photo", function()
        local catalog, Handler = setup({
            fs = { exists = { ["/photo.jpg"] = true }, directories = {} },
        })

        local r = Handler.importPhotos({ source_path = "/photo.jpg" })

        assert.is_true(r.success)
        assert.are.equal(1, r.imported)
    end)

    it("errors when source path does not exist", function()
        local _, Handler = setup({ fs = { exists = {} } })
        assert.has_error(function()
            Handler.importPhotos({ source_path = "/missing.jpg" })
        end)
    end)

    it("errors without source_path", function()
        local _, Handler = setup({ fs = {} })
        assert.has_error(function() Handler.importPhotos({}) end)
    end)

    it("imports multiple photos from directory and filters extensions", function()
        local catalog, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.txt", "/dir/c.png", "/dir/d.dng" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })
        assert.are.equal(3, r.imported)
    end)

    it("imports photos nested in subfolders", function()
        -- Photo libraries are organized as shoot/roll subfolders, so the source
        -- directory usually holds no photos itself. An immediate-directory walk
        -- enumerated nothing and failed with "No photos found to import"; the
        -- walk has to recurse.
        local _, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = {
                    "/dir/roll1/a.jpg",
                    "/dir/roll1/scans/b.tif",
                    "/dir/roll2/c.arw",
                },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.is_true(r.success)
        assert.are.equal(3, r.imported)
    end)

    it("acquires catalog write access per photo, not once for the batch", function()
        -- A batch-wide write lock wedges the bridge for the whole multi-minute
        -- import (issue #128); each photo must get its own short transaction so
        -- the exclusive lock is released between photos.
        local catalog, Handler = setup({
            fs = {
                exists = { ["/dir"] = true },
                directories = { ["/dir"] = true },
                dirContents = { "/dir/a.jpg", "/dir/b.png", "/dir/c.dng" },
            },
        })

        local r = Handler.importPhotos({ source_path = "/dir" })

        assert.are.equal(3, r.imported)
        assert.are.equal(3, catalog:getWriteAccessCount())
    end)
end)

describe('Import copy and errors', function()
    it('copies into the requested folder and imports the copy', function()
        local fs={exists={['/a.jpg']=true}}
        local catalog,h=setup({fs=fs})
        local added
        catalog.addPhoto=function(_,p) added=p;return helper.fakePhoto({path=p}) end
        local r=h.importPhotos({source_path='/a.jpg',destination='/copies'})
        assert.is_true(r.success);assert.are.equal('/copies/a.jpg',added)
        assert.are.same({{'/a.jpg','/copies/a.jpg'}},fs.copies)
    end)
    it('rejects destination collisions before copying', function()
        local fs={exists={['/a.jpg']=true,['/copies/a.jpg']=true}}
        local _,h=setup({fs=fs})
        assert.has_error(function() h.importPhotos({source_path='/a.jpg',destination='/copies'}) end)
        assert.is_nil(fs.copies)
    end)
    it('reports copy errors and refuses missing collections before import', function()
        local fs={exists={['/a.jpg']=true},copyError='disk full'}
        local _,h=setup({fs=fs})
        assert.has_error(function() h.importPhotos({source_path='/a.jpg',collection_name='Missing'}) end)
        local r=h.importPhotos({source_path='/a.jpg',destination='/copies'})
        assert.is_false(r.success);assert.are.equal(0,r.imported);assert.are.equal(1,#r.failures)
    end)
end)
