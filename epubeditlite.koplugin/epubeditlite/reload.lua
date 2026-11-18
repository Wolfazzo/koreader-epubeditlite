local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")

local Reload = {}
local font_size_tweak = "font_size_all_inherit"

function Reload.styleOverrides(ui)
    local config = ui.document.configurable
    local tweaks = ui.styletweak
    local embedded = config and config.embedded_css == 0
    local font_sizes = tweaks and tweaks.enabled and tweaks:isTweakEnabled(font_size_tweak)
    if embedded or font_sizes then
        return { embedded = embedded, font_sizes = font_sizes }
    end
end

function Reload.useBookStyles(settings, overrides)
    if overrides.embedded then settings:saveSetting("copt_embedded_css", 1) end
    if overrides.font_sizes then
        local tweaks = settings:readSetting("style_tweaks", {})
        tweaks[font_size_tweak] = false
        settings:saveSetting("style_tweaks", tweaks)
    end
    return settings:flush(nil, true) -- The custom metadata and cover are already in place.
end

function Reload.removeRenderCache(path)
    if not path then return end
    local cache_dir = require("datastorage"):getDataDir() .. "/cache/cr3cache"
    local directory = ffiutil.realpath(cache_dir)
    local cache = ffiutil.realpath(path)
    if not directory or not cache or cache:match("^(.*)/[^/]+%.cr3$") ~= directory then return end
    if require("libs/libkoreader-lfs").symlinkattributes(path, "mode") ~= "file" then return end
    local ok, err = os.remove(cache)
    if not ok then logger.warn("epubeditlite: could not remove old document cache", err) end
end

function Reload.refreshCover(file)
    local repo = package.loaded["lib/bookshelf_book_repository"]
    local bim = package.loaded["bookinfomanager"]
    if not (repo and repo.bimDelete and bim and repo.bimDelete(bim, file)) then
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
    end
    if repo and repo.forgetBook then repo.forgetBook(file) end
    local scaled = package.loaded["lib/bookshelf_scaled_cover_cache"]
    if scaled and scaled.drop then scaled:drop(file) end
    local spine = package.loaded["lib/bookshelf_spine_shelf"]
    if spine and spine.invalidateBook then spine.invalidateBook(file, true) end
    if repo then UIManager:broadcastEvent(Event:new("BookMetadataChanged")) end
end

return Reload
