-- Accept an unambiguous leaf name or a full "Set / Collection" path.
local M = {}

function M.find(catalog, selector, setsOnly)
    local exact, leaves = {}, {}
    local function consider(item, full)
        if full == selector then exact[#exact+1] = item end
        if item:getName() == selector then leaves[#leaves+1] = item end
    end
    local function walk(parent, prefix)
        if not setsOnly then
            for _, item in ipairs(parent:getChildCollections()) do consider(item, prefix .. item:getName()) end
        end
        for _, set in ipairs(parent:getChildCollectionSets()) do
            local full = prefix .. set:getName()
            if setsOnly then consider(set, full) end
            walk(set, full .. ' / ')
        end
    end
    walk(catalog, '')
    local found = selector:find(' / ', 1, true) and exact or leaves
    if #found > 1 then error('Ambiguous collection name; use its full path: ' .. selector) end
    return found[1]
end

return M
