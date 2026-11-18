local gettext = require("gettext")

local language = gettext.current_lang
if language == "C" and G_reader_settings then
    -- Some KOReader versions offer regional variants without their own MO file.
    language = G_reader_settings:readSetting("language") or language
end

local function loadCatalog(language)
    local base = language:match("^([a-z]+)")
    if not base or base == "en" or base == "posix" then return end
    local variants = {
        af = "af_ZA", bg = "bg_BG", it = "it_IT", ko = "ko_KR", lt = "lt_LT",
        nb = "nb_NO", nl = "nl_NL", pt = "pt_PT", zh = "zh_CN",
        zh_Hans = "zh_CN", zh_Hant = "zh_TW",
    }
    local folder = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "locale/"
    local selected = variants[language] or language
    local fallback = variants[base] or base
    local chunk = loadfile(folder .. selected .. ".lua")
    if not chunk and selected ~= fallback then chunk = loadfile(folder .. fallback .. ".lua") end
    if not chunk then return end
    local ok, translations = pcall(chunk)
    if ok and type(translations) == "table" then return translations end
end

-- KOReader restarts its interface after a language change. Load one catalog
-- with the plugin and leave shared UI strings to the native gettext catalog.
local translations
if type(language) == "string" then
    local locale = language:match("^[^%.@]+")
    if locale and locale:match("^[a-z][a-z][A-Za-z_]*$") then translations = loadCatalog(locale) end
end

return function(text)
    return translations and translations[text] or gettext(text)
end
