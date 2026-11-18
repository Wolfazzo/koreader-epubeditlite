local BD = require("ui/bidi")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("logger")
local Reload = require("epubeditlite/reload")
local _ = require("epubeditlite/i18n")
local T = ffiutil.template
local C = ffi.C

local EpubEditLite = WidgetContainer:extend{
    name = "epubeditlite",
    is_doc_only = true,
}

local button_id = "09_z_epubeditlite"
local max_drafts = 1024 * 1024
local max_save_reply = 1500
local staging_in_use = {}

local function message(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

local function failure(text, detail)
    logger.warn("epubeditlite:", detail)
    message(T(_("%1\n\n%2"), text, tostring(detail):gsub("^.-%.lua:%d+: ", "")))
end

local function charpos(text, byte)
    local _, count = text:sub(1, byte - 1):gsub("[^\128-\191]", "")
    return count + 1
end

local function entryName(name, entries)
    if entries[name] then return name end
    local decoded = name:gsub("%%(%x%x)", function(b) return string.char(tonumber(b, 16)) end)
    if entries[decoded] then return decoded end
end

function EpubEditLite:init()
    local document = self.ui.document
    if not self.ui.highlight or not document or document.info.has_pages
        or not document.file:lower():match("%.epub$") or not document.getHTMLFromXPointers then
        return
    end
    self.available = true
    self.ui.highlight:addToHighlightDialog(button_id, function(highlight)
        local selected = highlight.selected_text
        return {
            text = _("Edit EPUB"),
            show_in_highlight_dialog_func = function()
                return selected and selected.pos0 and selected.pos1 and selected.text and selected.text ~= ""
            end,
            callback = function() self:openSelection(highlight, selected) end,
        }
    end)
end

function EpubEditLite:onReaderReady()
    if not self.available then return end
    -- Recover only this book's staging file left by an interrupted save.
    local lfs = require("libs/libkoreader-lfs")
    local path = ffiutil.realpath(self.ui.document.file)
    if path then
        local dir = path:match("^(.*/)") .. ".epubeditlite-" .. require("ffi/sha2").md5(path:match("[^/]+$"))
        if not staging_in_use[dir] and lfs.symlinkattributes(dir, "mode") == "directory" then
            require("epubeditlite/zip").cleanup(dir)
        end
    end
end

local function selectedSource(document, selected, xhtml)
    -- Same serialization as View HTML, minus the selector-offset output.
    local html, sheets = document:getHTMLFromXPointers(selected.pos0, selected.pos1, 0x6830, true)
    local source
    for pos in (html or ""):gmatch("<DocFragment%s+()") do
        local attrs = xhtml.attributes(html, pos - 1)
        local current = attrs.Source and xhtml.decodeAttribute(attrs.Source.value)
        if not current or (source and current ~= source) then return end
        source = current
    end
    if not source then return end
    local context = document:getHTMLFromXPointer(selected.pos0, 0, true)
    if context and #context <= 8192 then
        context = xhtml.context(context)
    else
        context = nil
    end
    return source, sheets, context
end

local function orderedStylesheets(sheets, entries)
    local preferred, additional, seen = {}, {}, {}
    for _, value in ipairs(sheets or {}) do
        local name = entryName(value, entries)
        if name and name:lower():match("%.css$") and not seen[name] then
            preferred[#preferred + 1] = name
            seen[name] = true
        end
    end
    local count = #preferred
    for name in pairs(entries) do
        if name:lower():match("%.css$") and not seen[name] then additional[#additional + 1] = name end
    end
    table.sort(additional)
    for _, name in ipairs(additional) do preferred[#preferred + 1] = name end
    return preferred, count
end

function EpubEditLite:openSelection(highlight, selected)
    if self.session then return end
    if G_reader_settings:readSetting("document_metadata_folder") == "hash" then
        message(_("EPUB editing requires book metadata stored by path. This keeps reading statistics associated with the book."))
        return
    end
    local path = ffiutil.realpath(self.ui.document.file)
    local zip = require("epubeditlite/zip")
    local xhtml = require("epubeditlite/xhtml")
    local stamp = path and zip.stamp(path)
    if not stamp then
        message(_("The EPUB file is unavailable."))
        return
    end
    local ok, name, sheets, context = pcall(selectedSource, self.ui.document, selected, xhtml)
    if not ok then
        failure(_("Could not find the XHTML source."), name)
        return
    end
    if not name then
        message(_("Select a passage within one XHTML file."))
        return
    end
    local resource, err = zip.read(path, name)
    if not resource and name:find("%%%x%x") then
        local decoded = name:gsub("%%(%x%x)", function(b) return string.char(tonumber(b, 16)) end)
        resource, err = zip.read(path, decoded)
        if resource then name = decoded end
    end
    if not resource then
        failure(_("Could not open the XHTML source."), err)
        return
    end
    local valid, detail = pcall(xhtml.validateText, resource.text)
    if not valid then
        failure(_("Could not open the XHTML source."), detail)
        return
    end
    local list, linked_count = orderedStylesheets(sheets, resource.entries)
    local cursor_ok, byte = pcall(xhtml.cursor, resource.text, selected.text, context)
    local source = {
        original = resource.text, draft = resource.text,
        charpos = cursor_ok and byte and charpos(resource.text, byte) or 1,
    }
    self.session = {
        path = path, stamp = stamp, xhtml = name, css = list[1],
        sheets = list, linked_count = linked_count, files = { [name] = source },
        needle = selected.text, context = context,
        find_selection = not cursor_ok or not byte,
    }
    highlight:onClose()
    self:showEditor(name)
end

local function editorClass()
    local input = require("ui/widget/inputdialog")
    -- KOReader already delivers CloseWidget to the child InputText. Let the
    -- UIManager:close caller choose the refresh type for tab switches.
    return input:extend{ onCloseWidget = input.onClose }
end

function EpubEditLite:captureDraft()
    if self.editor then
        local file = self.session.files[self.session.active]
        file.draft = self.editor:getInputText()
    end
end

function EpubEditLite:closeEditor()
    local editor = self.editor
    self.editor = nil
    if editor then UIManager:close(editor, "ui") end
end

function EpubEditLite:closeModal()
    local modal = self.modal
    self.modal = nil
    if modal then UIManager:close(modal, "ui") end
end

function EpubEditLite:discard()
    self:closeModal()
    self:closeEditor()
    self.session = nil
end

function EpubEditLite:requestClose()
    if self.job or not self.session then return end
    self:captureDraft()
    for _name, file in pairs(self.session.files) do
        if file.draft ~= file.original then
            local box = require("ui/widget/confirmbox"):new{
                text = _("Discard unsaved EPUB changes?"),
                ok_text = _("Discard"),
                ok_callback = function() self.modal = nil; self:discard() end,
                cancel_callback = function() self.modal = nil end,
                dismissable = false,
            }
            self.modal = box
            UIManager:show(box)
            return
        end
    end
    self:discard()
end

local function filename(name)
    return name:match("[^/]+$") or name
end

function EpubEditLite:showEditor(name)
    local session = self.session
    local file = session.files[name]
    local is_html = name == session.xhtml
    session.active = name
    local buttons = {
        {
            { text = "XHTML", enabled = not is_html, callback = function() self:changeTab(session.xhtml) end },
            {
                text = "CSS", enabled = is_html and session.css ~= nil,
                callback = function() self:changeTab(session.css) end,
            },
        },
        {
            {
                text = is_html and _("Quick edits") or _("Stylesheets"),
                enabled = is_html or #session.sheets > 1,
                callback = function()
                    if is_html then self:showActions() else self:showSheets() end
                end,
            },
            { text = _("Save and return"), callback = function() self:save() end },
            { text = _("Close"), id = "close", callback = function() self:requestClose() end },
        },
    }
    local input = editorClass():new{
        title = BD.filepath(filename(name)),
        input = file.draft,
        input_face = require("ui/font"):getFace("infont"),
        text_type = "code",
        fullscreen = true,
        condensed = true,
        allow_newline = true,
        cursor_at_end = false,
        keyboard_visible = false,
        add_nav_bar = true,
        scroll_by_pan = true,
        buttons = buttons,
        view_pos_callback = function(top, cursor)
            if top and cursor then
                file.top, file.charpos = top, cursor
            else
                return file.top or 1, file.charpos or 1
            end
        end,
    }
    if is_html then input.search_value = session.needle end
    self.editor = input
    UIManager:show(input, "ui")
    if not file.top and file.charpos and file.charpos > 1 then
        input._input_widget.text_widget:moveCursorToCharPos(file.charpos)
        input._input_widget:resyncPos()
    end
    if is_html and session.find_selection then
        session.find_selection = nil
        require("ui/widget/notification"):notify(_("Use Find to locate the selection in the XHTML."))
    end
end

function EpubEditLite:changeTab(name)
    if self.job then return end
    local session = self.session
    if not name or name == session.active then return end
    self:captureDraft()
    if not session.files[name] then
        local zip = require("epubeditlite/zip")
        if zip.stamp(session.path) ~= session.stamp then
            message(_("The EPUB changed on disk. Reopen it before editing."))
            return
        end
        -- Keep only open/modified buffers. The stylesheet chooser still lists
        -- every stylesheet without reading their contents.
        local count = 0
        for key, file in pairs(session.files) do
            if key ~= session.xhtml and key ~= session.active and file.draft == file.original then
                session.files[key] = nil
            else
                count = count + #file.draft
            end
        end
        local resource, error_text = zip.read(session.path, name)
        if not resource then
            failure(_("Could not open the stylesheet."), error_text)
            return
        end
        if count + #resource.text > max_drafts then
            message(_("Too much source text is open for lightweight editing. Save your changes first."))
            return
        end
        local valid, detail = pcall(require("epubeditlite/xhtml").validateText, resource.text)
        if not valid then
            failure(_("Could not open the stylesheet."), detail)
            return
        end
        session.files[name] = { original = resource.text, draft = resource.text }
    end
    self:closeEditor()
    if name ~= session.xhtml then session.css = name end
    self:showEditor(name)
end

function EpubEditLite:showSheets()
    local session = self.session
    local buttons = {}
    for i, name in ipairs(session.sheets) do
        local label = i <= session.linked_count and filename(name) or name
        buttons[#buttons + 1] = {{
            text = BD.filepath(label),
            enabled = name ~= session.active,
            callback = function() self:closeModal(); self:changeTab(name) end,
        }}
    end
    buttons[#buttons + 1] = {{ text = _("Close"), callback = function() self:closeModal() end }}
    self.modal = require("ui/widget/buttondialog"):new{
        title = _("Stylesheets"), buttons = buttons, rows_per_page = 8,
        tap_close_callback = function() self.modal = nil end,
    }
    UIManager:show(self.modal)
end

function EpubEditLite:showActions()
    local function action(label, id)
        return {
            text = label,
            callback = function() self:closeModal(); self:applyAction(id) end,
        }
    end
    self.modal = require("ui/widget/buttondialog"):new{
        title = _("Quick edits for the reading selection"),
        buttons = {
            { action(_("Remove <span> tags"), "span") },
            { action(_("Remove class from <span>"), "class") },
            { action(_("Remove style from paragraphs"), "style") },
            {{
                text = _("Apply CSS class"),
                callback = function() self:closeModal(); self:askClass() end,
            }},
            {{ text = _("Close"), callback = function() self:closeModal() end }},
        },
        tap_close_callback = function() self.modal = nil end,
    }
    UIManager:show(self.modal)
end

function EpubEditLite:askClass()
    local input = editorClass():new{
        title = _("CSS class name"),
        stop_events_propagation = true,
        input = self.session.class or "",
        input_hint = "mia-classe",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() self:closeModal() end },
            {
                text = _("Apply"), is_enter_default = true,
                callback = function()
                    local class = self.modal:getInputText():match("^%s*(.-)%s*$")
                    if not class:match("^[%a_%-][%w_%-]*$") or #class > 80 then
                        message(_("Enter one class name using letters, digits, hyphens or underscores."))
                        return
                    end
                    self.session.class = class
                    self:closeModal()
                    self:applyAction("apply", class)
                end,
            },
        }},
    }
    self.modal = input
    UIManager:show(input)
    input:onShowKeyboard()
end

function EpubEditLite:applyAction(action, class)
    local session = self.session
    self:captureDraft()
    local file = session.files[session.xhtml]
    if #file.draft > require("epubeditlite/zip").max_text then
        message(_("The XHTML file exceeds the editing size limit."))
        return
    end
    local ok, text, reason, cursor = pcall(require("epubeditlite/xhtml").transform,
        file.draft, session.needle, session.context, action, class)
    if not ok then
        failure(_("Fix the XHTML before using a quick edit."), text)
    elseif reason == "selection" then
        message(_("The reading selection could not be identified uniquely in the current XHTML. Use Find or edit it by hand."))
    elseif not text then
        message(_("No matching tags can be safely changed in this selection."))
    else
        file.draft = text
        self.editor:setInputText(text, true)
        self.editor._input_widget.text_widget:moveCursorToCharPos(charpos(text, cursor))
        self.editor._input_widget:resyncPos()
        UIManager:setDirty(self.editor, "ui")
    end
end

local function readSaveReply(fd)
    -- The reply fits in a single write. Read only the available bytes, so even
    -- an inherited pipe descriptor cannot hold the interface waiting for EOF.
    local available = ffiutil.getNonBlockingReadSize(fd)
    local reply
    if available and available > 0 then
        local size = math.min(available, max_save_reply)
        local buffer = ffi.new("char[?]", size)
        local count = tonumber(C.read(fd, buffer, size))
        if count > 0 then reply = ffi.string(buffer, count) end
    end
    C.close(fd)
    return reply
end

local function reapCancelledSave(pid, dir)
    if not ffiutil.isSubProcessDone(pid) then
        UIManager:scheduleIn(0.5, reapCancelledSave, pid, dir)
        return
    end
    staging_in_use[dir] = nil
    require("epubeditlite/zip").cleanup(dir)
end

function EpubEditLite:cancelSave()
    local job = self.job
    if not job then return end
    self.job = nil
    UIManager:unschedule(job.poll)
    job.poll = nil
    C.close(job.pipe)
    if not ffiutil.isSubProcessDone(job.pid) then
        -- Signal the worker even if it has not created its process group yet.
        C.kill(job.pid, 9)
    end
    reapCancelledSave(job.pid, job.dir)
end

function EpubEditLite:confirmBookStyles(overrides)
    local lines = {}
    if overrides.embedded then lines[#lines + 1] = _("Embedded styles are disabled.") end
    if overrides.font_sizes then
        lines[#lines + 1] = T(_("‘%1’ is active."), _("Ignore publisher font sizes"))
    end
    local box = require("ui/widget/multiconfirmbox"):new{
        text = table.concat(lines, "\n") .. "\n\n" .. _("Use the EPUB styles for this book?"),
        choice1_text = _("Use EPUB styles"),
        choice2_text = _("Save as is"),
        dismissable = false,
        choice1_callback = function() self.modal = nil; self:save(true) end,
        choice2_callback = function() self.modal = nil; self:save(false) end,
        cancel_callback = function() self.modal = nil end,
    }
    self.modal = box
    UIManager:show(box)
end

function EpubEditLite:save(use_book_styles)
    if self.job or self.modal or not self.session then return end
    self:captureDraft()
    local session = self.session
    local zip = require("epubeditlite/zip")
    local xhtml = require("epubeditlite/xhtml")
    local chapter = session.xhtml
    local changes, total, changed_css = {}, 0, false
    for name, file in pairs(session.files) do
        if file.draft ~= file.original then
            total = total + #file.draft
            if #file.draft > zip.max_text or total > max_drafts then
                message(_("The edited source exceeds the size limit."))
                return
            end
            changes[name] = file.draft
            if name ~= chapter then changed_css = true end
        end
    end
    if not next(changes) then self:discard(); return end

    local original = session.files[chapter].original
    local changed_xhtml = changes[chapter] ~= nil
    local overrides = use_book_styles ~= false and Reload.styleOverrides(self.ui)
    if overrides and use_book_styles == nil
        and (changed_css or (changed_xhtml and xhtml.stylesChanged(original, changes[chapter]))) then
        self:confirmBookStyles(overrides)
        return
    end

    local dir = zip.tempDir(session.path)
    if staging_in_use[dir] then
        message(_("The previous save is still stopping."))
        return
    end
    local dialog = require("ui/widget/confirmbox"):new{
        text = _("Saving EPUB…"),
        icon = "notice-info",
        no_ok_button = true,
        dismissable = false,
        stop_events_propagation = true,
        cancel_callback = function() self:cancelSave() end,
    }
    local created, create_error = require("libs/libkoreader-lfs").mkdir(dir)
    if not created then
        failure(_("Could not create the temporary EPUB."), create_error)
        return
    end
    local temp = dir .. "/book.tmp"
    local path, stamp = session.path, session.stamp
    local fds = ffi.new("int[2]")
    if C.pipe(fds) ~= 0 then
        local err = ffi.string(C.strerror(ffi.errno()))
        zip.cleanup(dir)
        failure(_("Could not start EPUB saving."), err)
        return
    end
    local read_fd, write_fd = fds[0], fds[1]
    local pid, start_error = ffiutil.runInSubProcess(function()
        C.close(read_fd)
        local ok, result, err = pcall(function()
            for name, text in pairs(changes) do
                if name == chapter then
                    local valid, previous = pcall(xhtml.inspect, original)
                    xhtml.validate(text, valid and previous or { unknown = {} })
                else
                    xhtml.validateText(text)
                end
            end
            return zip.stage(path, temp, stamp, changes)
        end)
        local status = ok and result and "OK" or tostring(ok and err or result)
        ffiutil.writeToFD(write_fd, status:sub(1, max_save_reply), true)
    end)
    C.close(write_fd)
    if not pid then
        C.close(read_fd)
        zip.cleanup(dir)
        failure(_("Could not start EPUB saving."), start_error)
        return
    end
    local job = { pid = pid, pipe = read_fd, dir = dir, temp = temp, dialog = dialog }
    self.job = job
    staging_in_use[dir] = true
    job.poll = function()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(0.15, job.poll)
            return
        end
        local result = readSaveReply(read_fd)
        job.poll = nil
        self.job = nil
        staging_in_use[dir] = nil
        UIManager:close(dialog, "ui")
        if result ~= "OK" then
            zip.cleanup(dir)
            failure(_("The EPUB could not be saved."), result or _("The save process stopped."))
        elseif zip.stamp(path) ~= stamp then
            zip.cleanup(dir)
            message(_("The EPUB changed on disk. Your draft is still open."))
        else
            self:commit(job, changed_xhtml, use_book_styles and overrides)
        end
    end
    UIManager:show(dialog, "ui")
    UIManager:scheduleIn(0.10, job.poll)
end

local function restorePosition(reader, pointer, context, fragment, percent)
    local doc = reader.document
    if pointer and doc:isXPointerInDocument(pointer) then
        if not context or doc:getTextFromXPointer(pointer) == context then return end
    end
    if context and #context >= 8 and #context <= 180 then
        local items = doc:findAllText(context, false, 0, 3, false)
        if items and #items == 1 and items[1].start
            and (not fragment or items[1].start:sub(1, #fragment) == fragment) then
            reader:handleEvent(Event:new("GotoXPointer", items[1].start))
            return
        end
    end
    while pointer do
        pointer = pointer:match("^(.*)/[^/]+$")
        if pointer and pointer ~= "" and pointer ~= "/body" and doc:isXPointerInDocument(pointer) then
            reader:handleEvent(Event:new("GotoXPointer", pointer))
            return
        end
    end
    if fragment and doc:isXPointerInDocument(fragment) then
        reader:handleEvent(Event:new("GotoXPointer", fragment))
    elseif percent then
        reader:handleEvent(Event:new("GotoPercent", percent))
    end
end

function EpubEditLite:commit(job, changed_xhtml, overrides)
    local zip = require("epubeditlite/zip")
    local registry = require("document/documentregistry")
    local session, ui = self.session, self.ui
    local book_file = ui.document.file
    if (registry:getReferenceCount(book_file) or 0) > 1 then
        zip.cleanup(job.dir)
        message(_("The book is still in use. Your draft is still open."))
        return
    end

    local pointer = ui.rolling.xpointer or ui.document:getXPointer()
    local context = changed_xhtml and pointer and ui.document:getTextFromXPointer(pointer)
    if context and #context > 180 then context = nil end
    local fragment = pointer and pointer:match("^(/body/DocFragment[^/]*)/")
    local percent = 100 * ui:getCurrentPage() / math.max(1, ui.document:getPageCount())
    local cache_path = ui.document:getCacheFilePath()
    local settings = ui.doc_settings
    local replaced, rename_error, styles_failed
    settings:makeTrue("annotations_externally_modified")
    ui.document:invalidateCacheFile()
    self:discard()
    ui:reloadDocument(function()
        if (registry:getReferenceCount(book_file) or 0) > 0 then
            rename_error = _("The book is still in use. Your draft is still open.")
        elseif zip.stamp(session.path) ~= session.stamp then
            rename_error = _("The EPUB changed on disk.")
        else
            replaced, rename_error = os.rename(job.temp, session.path)
        end
        zip.cleanup(job.dir)
        if replaced then
            local synced, err = ffiutil.fsyncDirectory(session.path)
            if not synced then logger.warn("epubeditlite: could not sync book directory", err) end
            local ok_cache, cache_error = pcall(Reload.removeRenderCache, cache_path)
            if not ok_cache then logger.warn("epubeditlite: could not remove old document cache", cache_error) end
            if overrides then
                local ok_styles, applied = pcall(Reload.useBookStyles, settings, overrides)
                if not ok_styles or not applied then
                    styles_failed = true
                    logger.warn("epubeditlite: could not save book style settings", applied)
                end
            end
            session = nil
        end
    end, true, function()
        UIManager:nextTick(function()
            local reader = require("apps/reader/readerui").instance
            if not reader or not reader.document or reader.document.file ~= book_file then return end
            if replaced then
                local ok, err = pcall(restorePosition, reader, pointer, context, fragment, percent)
                if not ok then logger.warn("epubeditlite: could not restore reading position", err) end
                local cover_ok, cover_error = pcall(Reload.refreshCover, book_file)
                if not cover_ok then logger.warn("epubeditlite: could not refresh cover cache", cover_error) end
                require("ui/widget/notification"):notify(styles_failed
                    and _("EPUB saved. Could not update this book's reading styles.") or _("EPUB saved"))
            else
                local plugin = reader.epubeditlite
                if plugin then
                    plugin.session = session
                    plugin:showEditor(session.active)
                end
                failure(_("Could not replace the EPUB."), rename_error)
            end
        end)
    end)
end

function EpubEditLite:onCloseDocument()
    local job = self.job
    if job then
        self:cancelSave()
        UIManager:close(job.dialog, "ui")
    end
    self:discard()
end

return EpubEditLite
