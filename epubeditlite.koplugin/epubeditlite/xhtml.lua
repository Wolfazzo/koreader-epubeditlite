local util = require("util")
local utf8 = require("ffi/utf8proc")

local XHTML = {}
local name_pattern = "[%a_:\128-\255][%w_:.\128-\255%-]*"
local xml_entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local html_entities = { nbsp = " ", shy = "", ensp = " ", emsp = " ", thinsp = " ", lsquo = "‘",
    rsquo = "’", ldquo = "“", rdquo = "”", ndash = "–", mdash = "—", hellip = "…" }
local blocks = { body = true, p = true, div = true, br = true, li = true, h1 = true, h2 = true,
    h3 = true, h4 = true, h5 = true, h6 = true, td = true, tr = true, section = true,
    blockquote = true, pre = true, hr = true }
local hidden = { style = true, script = true, svg = true, title = true }

local function xmlCodepoint(n)
    return n and (n == 9 or n == 10 or n == 13 or (n >= 32 and n <= 0xD7FF)
        or (n >= 0xE000 and n <= 0xFFFD) or (n >= 0x10000 and n <= 0x10FFFF))
end

function XHTML.validateText(text)
    assert(not text:find("[%z\1-\8\11\12\14-\31]"), "Invalid control character")
    if text:find("[\128-\255]") then
        local _, valid = utf8.count(text)
        assert(valid, "Invalid UTF-8")
    end
end

local function entity(text, i)
    local token, last = text:match("^&([#%w_:%.%-]+);()", i)
    assert(token, "Invalid XML entity")
    if token:sub(1, 1) == "#" then
        local hex = token:match("^#x([0-9A-Fa-f]+)$")
        local dec = token:match("^#([0-9]+)$")
        local n = hex and tonumber(hex, 16) or dec and tonumber(dec)
        assert(xmlCodepoint(n), "Invalid numeric XML entity")
        return util.unicodeCodepointToUtf8(n), last
    end
    assert(token:match("^" .. name_pattern .. "$"), "Invalid XML entity name")
    local known = xml_entities[token] or html_entities[token]
    if known then return known, last end
    local source = text:sub(i, last - 1)
    return util.htmlEntitiesToUtf8(source), last
end

local function validateEntities(text, unknown)
    local pos = 1
    while true do
        local i = text:find("&", pos, true)
        if not i then return end
        local decoded
        decoded, pos = entity(text, i)
        if decoded == text:sub(i, pos - 1) then unknown[decoded] = true end
    end
end

function XHTML.decodeAttribute(text)
    return (text:gsub("&[#%w_:%.%-]+;", function(value)
        return (entity(value, 1))
    end))
end

function XHTML.attributes(text, pos)
    local attrs = {}
    while true do
        local next_pos = text:match("^%s*()", pos)
        local ch = text:sub(next_pos, next_pos)
        if ch == ">" or text:sub(next_pos, next_pos + 1) == "/>" then
            return attrs, next_pos + (ch == ">" and 1 or 2), ch == "/"
        end
        assert(next_pos > pos, "Missing space between attributes")
        local name, value_pos = text:match("^(" .. name_pattern .. ")%s*=%s*()", next_pos)
        assert(name and not attrs[name], "Invalid or duplicate XHTML attribute")
        local quote = text:sub(value_pos, value_pos)
        assert(quote == '"' or quote == "'", "Unquoted XHTML attribute")
        local last = assert(text:find(quote, value_pos + 1, true), "Unclosed XHTML attribute")
        local value = text:sub(value_pos + 1, last - 1)
        assert(not value:find("<", 1, true), "Unescaped < in XHTML attribute")
        attrs[name] = { first = pos, last = last, value = value }
        pos = last + 1
    end
end

local function plainChar(value)
    if value:find("^%s+$") or value == "\194\160" or value == "\226\128\175" then return " " end
    if value == "\194\173" or value == "\226\128\139" then return "" end
    return value
end

-- For a single text node, emit normalized bytes and their source range. Only
-- selected nodes are visited a second time to map normalized offsets back to XHTML.
local function projectNode(text, first, last, cdata, emit)
    local i = first
    while i <= last do
        local a = text:find("[&%s\194\226]", i) or last + 1
        if a > last then a = last + 1 end
        if a > i then
            emit(text:sub(i, a - 1), i, a - 1, true)
            i = a
        else
            local value, after
            if not cdata and text:byte(i) == 38 then
                value, after = entity(text, i)
            else
                value = text:match("^[%z\1-\127\194-\244][\128-\191]*", i) or text:sub(i, i)
                after = i + #value
            end
            emit(plainChar(value), i, after - 1)
            i = after
        end
    end
end

function XHTML.normalize(text)
    return (text:gsub("\194\160", " "):gsub("\226\128\175", " "):gsub("\194\173", "")
        :gsub("\226\128\139", ""):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function scan(text, projection, fragment)
    XHTML.validateText(text)
    local pos = text:sub(1, 3) == "\239\187\191" and 4 or 1
    local declaration = text:match("^<%?xml%s+(.-)%?>", pos)
    local encoding = declaration and declaration:match("encoding%s*=%s*['\"]([%w%-_]+)['\"]")
    if encoding then
        encoding = encoding:lower()
        assert(encoding == "utf-8" or (encoding == "us-ascii" and not text:find("[\128-\255]")),
            "Unsupported XHTML encoding")
    end
    local stack, parts, runs, nodes, unknown = {}, {}, {}, {}, {}
    local length, prev_space, root, body, doctype = 0, true, false, false, false
    local function append(value)
        if not projection or value == "" or (value == " " and prev_space) then return end
        parts[#parts + 1] = value
        length = length + #value
        prev_space = value == " "
    end
    local function chars(first, last, cdata)
        local parent = stack[#stack]
        if first > last then return end
        local raw = text:sub(first, last)
        if not cdata then
            assert(not raw:find("]]>", 1, true), "Invalid XML text")
            validateEntities(raw, unknown)
        end
        if not parent then
            assert(not cdata and not raw:find("%S"), "Text outside the XHTML root")
        elseif projection and parent.visible then
            local start, leading_space = length + 1, prev_space
            projectNode(text, first, last, cdata, append)
            if length >= start then
                runs[#runs + 1] = { first = first, last = last, a = start, b = length,
                    space = leading_space, parent = parent, cdata = cdata }
            end
        end
    end
    while pos <= #text do
        local tag = text:find("<", pos, true) or #text + 1
        chars(pos, tag - 1)
        if tag > #text then break end
        local parent = stack[#stack]
        if text:sub(tag, tag + 3) == "<!--" then
            local finish = assert(text:find("--", tag + 4, true), "Unclosed XML comment")
            assert(text:sub(finish + 2, finish + 2) == ">", "Invalid XML comment")
            pos = finish + 3
        elseif text:sub(tag, tag + 8) == "<![CDATA[" then
            local finish = assert(text:find("]]>", tag + 9, true), "Unclosed CDATA")
            chars(tag + 9, finish - 1, true)
            pos = finish + 3
        elseif text:sub(tag, tag + 1) == "<?" then
            assert(text:match("^<%?(" .. name_pattern .. ")", tag), "Invalid XML instruction")
            pos = assert(text:find("?>", tag + 2, true), "Unclosed XML instruction") + 2
        elseif text:match("^<!DOCTYPE%s+html[%s>]", tag) then
            assert(not root and not doctype, "Unexpected XHTML doctype")
            doctype = true
            pos = text:match("^<!DOCTYPE%s+html%s*>()", tag)
                or text:match([[^<!DOCTYPE%s+html%s+PUBLIC%s+"[^"]*"%s+"[^"]*"%s*>()]], tag)
                or text:match([[^<!DOCTYPE%s+html%s+PUBLIC%s+'[^']*'%s+'[^']*'%s*>()]], tag)
                or text:match([[^<!DOCTYPE%s+html%s+SYSTEM%s+"[^"]*"%s*>()]], tag)
                or text:match([[^<!DOCTYPE%s+html%s+SYSTEM%s+'[^']*'%s*>()]], tag)
            assert(pos, "Unsupported XHTML doctype")
        elseif text:sub(tag, tag + 1) == "</" then
            local name, after = text:match("^</(" .. name_pattern .. ")%s*>()", tag)
            assert(parent and name == parent.name, "Unbalanced XHTML tags")
            parent.close, parent.b = tag, length
            stack[#stack] = nil
            if blocks[parent.local_name] and parent.visible then append(" ") end
            pos = after
        else
            local name, attrs_at = text:match("^<(" .. name_pattern .. ")()", tag)
            assert(name, "Invalid XHTML tag")
            local local_name = name:match("[^:]+$")
            if not parent then
                assert(not root and (fragment or local_name == "html"), "XHTML must have one html root")
                root = true
            elseif local_name == "body" and #stack == 1 then
                assert(not body, "Multiple XHTML body elements")
                body = true
            end
            local attrs, after, empty = XHTML.attributes(text, attrs_at)
            for _, attr in pairs(attrs) do validateEntities(attr.value, unknown) end
            local visible = ((not parent and fragment) or local_name == "body" or (parent and parent.visible))
                and not hidden[local_name]
            if visible and blocks[local_name] then append(" ") end
            local node = { name = name, local_name = local_name, attrs = attrs, first = tag,
                inner = after, a = length + 1, visible = visible }
            if visible and (local_name == "span" or local_name == "p") then
                nodes[#nodes + 1] = node
            end
            if not empty then
                assert(#stack < 128, "XHTML is nested too deeply")
                stack[#stack + 1] = node
            end
            pos = after
        end
    end
    assert(root and (body or fragment) and #stack == 0, "Incomplete XHTML")
    return { text = projection and table.concat(parts) or nil, runs = runs, nodes = nodes, unknown = unknown }
end

function XHTML.validate(text, original)
    local current = scan(text, false)
    if next(current.unknown) then
        for name in pairs(current.unknown) do
            assert(original.unknown[name], "Unknown XML entity " .. name)
        end
    end
end

function XHTML.inspect(text)
    return scan(text, false)
end

local function markupChunks(text)
    local pos = 1
    return function()
        local first = text:find("<", pos, true)
        if not first then return end
        local last
        if text:sub(first, first + 3) == "<!--" then
            last = select(2, text:find("-->", first + 4, true))
        elseif text:sub(first, first + 8) == "<![CDATA[" then
            last = select(2, text:find("]]>", first + 9, true))
        else
            last = text:find("[>'\"]", first + 1)
            while last and text:byte(last) ~= 62 do
                local end_quote = text:find(text:sub(last, last), last + 1, true)
                last = end_quote and text:find("[>'\"]", end_quote + 1)
            end
            local name = last and text:match("^<(" .. name_pattern .. ")", first)
            if name and (name == "style" or name:match(":style$")) and text:sub(last - 1, last - 1) ~= "/" then
                last = (text:find("</" .. name, last + 1, true) or #text + 1) - 1
            end
        end
        pos = (last or #text) + 1
        return text:sub(first, pos - 1)
    end
end

function XHTML.stylesChanged(original, draft)
    -- Skip ordinary text edits when offering to change reader style settings.
    local original_markup, draft_markup = markupChunks(original), markupChunks(draft)
    while true do
        local before, after = original_markup(), draft_markup()
        if before ~= after then return true end
        if not before then return false end
    end
end

function XHTML.context(html)
    local ok, doc = pcall(scan, html, true, true)
    return ok and XHTML.normalize(doc.text) or nil
end

local function countMatches(text, needle)
    local first, last = text:find(needle, 1, true)
    return first, last, first and text:find(needle, first + 1, true)
end

local function sourceRange(text, run, lo, hi)
    local pos, was_space = run.a, run.space
    local first, last
    projectNode(text, run.first, run.last, run.cdata, function(value, a, b, linear)
        if value == "" or (value == " " and was_space) then return end
        if lo >= pos and lo < pos + #value then
            first = linear and a + lo - pos or a
        end
        if hi >= pos and hi < pos + #value then
            last = linear and a + hi - pos or b
        end
        pos, was_space = pos + #value, value == " "
    end)
    return first, last
end

local function locate(text, needle, context)
    local doc = scan(text, true)
    needle = XHTML.normalize(needle)
    if needle == "" then return nil end
    local lo, hi, multiple = countMatches(doc.text, needle)
    if multiple and context then
        local start, _, ctx_multiple = countMatches(doc.text, context)
        local rel, _, rel_multiple = countMatches(context, needle)
        if start and not ctx_multiple and rel and not rel_multiple then
            lo, hi, multiple = start + rel - 1, start + rel + #needle - 2, nil
        end
    end
    if not lo or multiple then return nil end
    local segments = {}
    for _, run in ipairs(doc.runs) do
        if run.a > hi then break end
        if run.b >= lo then
            local first, last = sourceRange(text, run, math.max(lo, run.a), math.min(hi, run.b))
            if first and last then segments[#segments + 1] = { first = first, last = last, run = run } end
        end
    end
    if #segments == 0 then return nil end
    return doc, lo, hi, segments
end

function XHTML.cursor(text, needle, context)
    local doc, _, _, segments = locate(text, needle, context)
    return doc and segments[1].first
end

local function addEdit(edits, a, b, value)
    assert(value == nil or type(value) == "string", "Invalid XHTML replacement")
    edits[#edits + 1] = { a = a, b = b, value = value or "" }
end

local function spanEdits(text, doc, lo, hi, segments, action, edits)
    local left, right = segments[1], segments[#segments]
    for _, node in ipairs(doc.nodes) do
        local attr = node.attrs.class
        if node.local_name == "span" and node.close and node.a <= hi and node.b >= lo
            and (action ~= "class" or attr) then
            local full = not doc.text:sub(node.a, lo - 1):find("%S")
                and not doc.text:sub(hi + 1, node.b):find("%S")
            local anchored = node.attrs.id or node.attrs["xml:id"] or node.attrs.name
            local scoped = node.attrs.xmlns ~= nil
            for name in pairs(node.attrs) do
                if name:match("^xmlns:") then scoped = true; break end
            end
            if full and action == "class" then
                addEdit(edits, attr.first, attr.last)
            elseif full and not anchored and not scoped then
                -- string.find returns two offsets. Keep the single-byte match
                -- position separate from addEdit's replacement text.
                local close_end = assert(text:find(">", node.close, true))
                addEdit(edits, node.first, node.inner - 1)
                addEdit(edits, node.close, close_end)
            elseif not full and not anchored and not scoped and left.run == right.run
                and left.run.parent == node and not left.run.cdata
                and left.run.first == node.inner and right.run.last == node.close - 1 then
                -- Split a plain span so the unselected prefix/suffix retains its formatting.
                local prefix = text:sub(node.inner, left.first - 1)
                local selected = text:sub(left.first, right.last)
                local suffix = text:sub(right.last + 1, node.close - 1)
                local open = text:sub(node.first, node.inner - 1)
                local close_end = assert(text:find(">", node.close, true))
                local close = text:sub(node.close, close_end)
                if action == "class" then
                    selected = text:sub(node.first, attr.first - 1) .. text:sub(attr.last + 1, node.inner - 1)
                        .. selected .. close
                end
                local replacement = (prefix ~= "" and open .. prefix .. close or "") .. selected
                    .. (suffix ~= "" and open .. suffix .. close or "")
                addEdit(edits, node.first, close_end, replacement)
            end
        end
    end
end

function XHTML.transform(text, needle, context, action, class)
    local doc, lo, hi, segments = locate(text, needle, context)
    if not doc then return nil, "selection" end
    local edits = {}
    if action == "apply" then
        assert(class and class:match("^[%a_%-][%w_%-]*$") and #class <= 80, "Invalid CSS class name")
        for _, selection in ipairs(segments) do
            if selection.run.cdata then return nil, "unsafe" end
            local prefix = selection.run.parent.name:match("^(.*:)")
            -- Inline XHTML inside a prefixed document must use its XHTML prefix.
            local tag = (prefix or "") .. "span"
            addEdit(edits, selection.first, selection.last, ('<%s class="%s">%s</%s>'):format(
                tag, class, text:sub(selection.first, selection.last), tag))
        end
    elseif action == "style" then
        for _, node in ipairs(doc.nodes) do
            local attr = node.attrs.style
            if node.local_name == "p" and attr and node.close and node.a <= hi and node.b >= lo then
                addEdit(edits, attr.first, attr.last)
            end
        end
    else
        spanEdits(text, doc, lo, hi, segments, action, edits)
    end
    if #edits == 0 then return nil, "unsafe" end
    table.sort(edits, function(a, b) return a.a < b.a end)
    local pieces, first = {}, 1
    local cursor = segments[1].first
    local delta = 0
    for _, edit in ipairs(edits) do
        assert(edit.a >= first, "Overlapping XHTML edits")
        pieces[#pieces + 1] = text:sub(first, edit.a - 1)
        pieces[#pieces + 1] = edit.value
        first = edit.b + 1
        if edit.b < cursor then
            delta = delta + #edit.value - (edit.b - edit.a + 1)
        elseif edit.a < cursor then
            cursor = edit.a
        end
    end
    pieces[#pieces + 1] = text:sub(first)
    return table.concat(pieces), nil, math.max(1, cursor + delta)
end

return XHTML
