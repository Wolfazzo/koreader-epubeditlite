local ffi = require("ffi")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local band, bnot = bit.band, bit.bnot
require("ffi/zlib_h")

ffi.cdef[[
typedef struct {
    const unsigned char *next_in;
    unsigned int avail_in;
    unsigned long total_in;
    unsigned char *next_out;
    unsigned int avail_out;
    unsigned long total_out;
    char *msg;
    void *state, *zalloc, *zfree, *opaque;
    int data_type;
    unsigned long adler, reserved;
} epubeditlite_z_stream;
const char *zlibVersion(void);
int inflateInit2_(epubeditlite_z_stream *, int, const char *, int);
int inflate(epubeditlite_z_stream *, int);
int inflateEnd(epubeditlite_z_stream *);
int chmod(const char *, unsigned int);
]]

local z = ffi.loadlib("z", 1)
local Zip = { max_text = 512 * 1024 }
local central_limit = 4 * 1024 * 1024
local copy_size = 256 * 1024

local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    return a + 256 * b
end

local function u32(s, i)
    return u16(s, i) + 65536 * u16(s, i + 2)
end

local function le16(n)
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function le32(n)
    return le16(n) .. le16(math.floor(n / 65536))
end

local function read(file, count)
    if count == 0 then return "" end
    local data = assert(file:read(count), "Incomplete ZIP")
    assert(#data == count, "Incomplete ZIP")
    return data
end

local function crc(text)
    return tonumber(z.crc32(0, text, #text))
end

local function hasZip64Extra(extra)
    local i = 1
    while i <= #extra do
        assert(i + 3 <= #extra, "Invalid ZIP extra field")
        local tag, size = u16(extra, i), u16(extra, i + 2)
        if tag == 1 then return true end
        i = i + 4 + size
        assert(i <= #extra + 1, "Invalid ZIP extra field")
    end
end

local function directory(file)
    local size = assert(file:seek("end"))
    assert(size >= 22 and size < 0xFFFFFFFF, "Unsupported EPUB size")
    local start = math.max(0, size - 65557)
    assert(file:seek("set", start))
    local tail = read(file, size - start)
    local eocd
    for i = #tail - 21, 1, -1 do
        if tail:sub(i, i + 3) == "PK\005\006" and i + 21 + u16(tail, i + 20) == #tail then
            eocd = tail:sub(i)
            break
        end
    end
    assert(eocd and u32(eocd, 5) == 0 and u16(eocd, 9) == u16(eocd, 11),
        "Invalid or split ZIP")
    local offset, bytes, count = u32(eocd, 17), u32(eocd, 13), u16(eocd, 11)
    assert(count > 0 and count <= 16384 and bytes <= central_limit
        and offset + bytes == size - #eocd, "ZIP64 or oversized ZIP directory")
    assert(file:seek("set", offset))
    local entries, by_name, ordered = {}, {}, {}
    local remaining = bytes
    for i = 1, count do
        assert(remaining >= 46, "Incomplete ZIP directory")
        local header = read(file, 46)
        assert(header:sub(1, 4) == "PK\001\002" and u16(header, 35) == 0, "Invalid ZIP entry")
        local name_len, extra_len, comment_len = u16(header, 29), u16(header, 31), u16(header, 33)
        remaining = remaining - 46 - name_len - extra_len - comment_len
        assert(remaining >= 0 and name_len > 0, "Invalid ZIP entry length")
        local name, extra = read(file, name_len), read(file, extra_len)
        assert(not by_name[name] and not name:find("%z") and not hasZip64Extra(extra), "Ambiguous or ZIP64 entry")
        local entry = {
            name = name, header = header, suffix = name .. extra .. read(file, comment_len),
            flags = u16(header, 9), method = u16(header, 11), crc = u32(header, 17),
            compressed = u32(header, 21), size = u32(header, 25), offset = u32(header, 43),
        }
        assert(entry.offset < offset and (entry.method == 0 or entry.method == 8)
            and band(entry.flags, 0x2041) == 0, "Unsupported ZIP entry")
        entries[i], ordered[i], by_name[name] = entry, entry, entry
    end
    assert(remaining == 0, "Unsupported ZIP directory records")
    table.sort(ordered, function(a, b) return a.offset < b.offset end)
    for i, entry in ipairs(ordered) do
        entry.limit = ordered[i + 1] and ordered[i + 1].offset or offset
        assert(entry.offset + 30 + #entry.name + entry.compressed <= entry.limit, "Overlapping ZIP entries")
    end
    local mime = ordered[1]
    assert(mime.name == "mimetype" and mime.offset == 0 and mime.method == 0 and mime.size == 20,
        "Missing EPUB mimetype")
    assert(not by_name["META-INF/rights.xml"] and not by_name["META-INF/signatures.xml"],
        "This EPUB is protected or signed")
    return { entries = entries, ordered = ordered, by_name = by_name, offset = offset, eocd = eocd }
end

local function localHeader(file, entry)
    assert(file:seek("set", entry.offset))
    local header = read(file, 30)
    assert(header:sub(1, 4) == "PK\003\004" and u16(header, 7) == entry.flags
        and u16(header, 9) == entry.method, "Inconsistent ZIP headers")
    local name_len, extra_len = u16(header, 27), u16(header, 29)
    assert(name_len == #entry.name and entry.offset + 30 + name_len + extra_len + entry.compressed <= entry.limit,
        "Invalid ZIP data range")
    assert(read(file, name_len) == entry.name, "Inconsistent ZIP name")
    return header, read(file, extra_len)
end

local function entryText(file, entry)
    assert(entry and entry.size <= Zip.max_text and entry.compressed <= Zip.max_text + 65536,
        "Missing or oversized EPUB resource")
    local _, extra = localHeader(file, entry)
    if entry.name == "mimetype" then
        assert(#extra == 0, "Invalid EPUB mimetype header")
    end
    local data = read(file, entry.compressed)
    if entry.method == 8 then
        local output = ffi.new("uint8_t[?]", entry.size + 1)
        local stream = ffi.new("epubeditlite_z_stream[1]")
        assert(z.inflateInit2_(stream, -15, z.zlibVersion(), ffi.sizeof(stream[0])) == 0, "Cannot start ZIP decompression")
        stream[0].next_in, stream[0].avail_in = data, #data
        stream[0].next_out, stream[0].avail_out = output, entry.size + 1
        local status = z.inflate(stream, 4)
        local total_in, total_out = tonumber(stream[0].total_in), tonumber(stream[0].total_out)
        z.inflateEnd(stream)
        assert(status == 1 and total_out == entry.size and total_in == #data, "Invalid deflated ZIP entry")
        data = ffi.string(output, total_out)
    end
    assert(#data == entry.size and crc(data) == entry.crc, "Incorrect ZIP entry checksum")
    return data
end

local function withArchive(path, operation)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local ok, result = pcall(function()
        local archive = directory(file)
        assert(entryText(file, archive.by_name.mimetype) == "application/epub+zip", "Invalid EPUB mimetype")
        return operation(file, archive)
    end)
    local closed, close_error = file:close()
    if not ok then return nil, result end
    if not closed then return nil, close_error end
    return result
end

function Zip.read(path, name)
    return withArchive(path, function(file, archive)
        return { text = entryText(file, archive.by_name[name]), entries = archive.by_name }
    end)
end

function Zip.stamp(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    return table.concat({ attr.dev, attr.ino, attr.size, attr.modification, attr.change }, "/")
end

function Zip.tempDir(path)
    return assert(path:match("^(.*/)")) .. ".epubeditlite-" .. md5(path:match("[^/]+$"))
end

function Zip.cleanup(dir)
    if lfs.symlinkattributes(dir, "mode") ~= "directory" then return end
    local temp = dir .. "/book.tmp"
    if lfs.symlinkattributes(temp, "mode") == "file" then
        os.remove(temp)
    end
    lfs.rmdir(dir)
end

local function compressedText(text)
    local bound = tonumber(z.compressBound(#text))
    local output = ffi.new("uint8_t[?]", bound)
    local length = ffi.new("unsigned long[1]", bound)
    assert(z.compress2(output, length, text, #text, 1) == 0, "ZIP compression failed")
    local size = tonumber(length[0]) - 6
    if size >= #text then return text, 0 end
    -- compress2 emits a two-byte zlib header and a four-byte Adler-32 trailer.
    return ffi.string(output + 2, size), 8
end

local function copyRange(input, output, first, last)
    local remaining = last - first
    if remaining == 0 then return end
    assert(input:seek("set", first))
    while remaining > 0 do
        local size = math.min(remaining, copy_size)
        assert(output:write(read(input, size)))
        remaining = remaining - size
    end
end

local function replaceEntry(input, output, entry, text)
    assert(#text <= Zip.max_text, "Edited resource is too large")
    local local_header, extra = localHeader(input, entry)
    assert(not hasZip64Extra(extra), "ZIP64 edited entry")
    local data, method = compressedText(text)
    local flags = band(entry.flags, bnot(0x000E))
    local fields = le32(crc(text)) .. le32(#data) .. le32(#text)
    local local_record = local_header:sub(1, 6) .. le16(flags) .. le16(method)
        .. local_header:sub(11, 14) .. fields .. local_header:sub(27) .. entry.name .. extra
    assert(output:write(local_record, data))
    entry.header = entry.header:sub(1, 8) .. le16(flags) .. le16(method)
        .. entry.header:sub(13, 16) .. fields .. entry.header:sub(29)
end

local function writeArchive(input, output, archive, changes)
    local source_pos, delta = 0, 0
    for _, entry in ipairs(archive.ordered) do
        entry.new_offset = entry.offset + delta
        local text = changes[entry.name]
        if text then
            copyRange(input, output, source_pos, entry.offset)
            assert(output:seek() == entry.new_offset)
            replaceEntry(input, output, entry, text)
            source_pos = entry.limit
            delta = assert(output:seek()) - source_pos
        end
    end
    copyRange(input, output, source_pos, archive.offset)
    local central_start = assert(output:seek())
    for _, entry in ipairs(archive.entries) do
        assert(entry.new_offset >= 0 and entry.new_offset < 0xFFFFFFFF, "Output needs ZIP64")
        assert(output:write(entry.header:sub(1, 42), le32(entry.new_offset), entry.suffix))
    end
    local finish = assert(output:seek())
    assert(finish + #archive.eocd < 0xFFFFFFFF, "Output needs ZIP64")
    assert(output:write(archive.eocd:sub(1, 12), le32(finish - central_start),
        le32(central_start), archive.eocd:sub(21)))
    assert(output:flush())
    assert(ffiutil.fsyncOpenedFile(output))
end

function Zip.stage(path, temp, stamp, changes)
    if Zip.stamp(path) ~= stamp then return nil, "The EPUB changed on disk" end
    local result, err = withArchive(path, function(input, archive)
        for name in pairs(changes) do
            assert(name ~= "mimetype" and archive.by_name[name], "Edited resource is missing")
        end
        local output = assert(io.open(temp, "wb"))
        local ok, failure = pcall(writeArchive, input, output, archive, changes)
        local closed, close_error = output:close()
        assert(ok, failure)
        assert(closed, close_error)
        return true
    end)
    if not result then return nil, err end
    local permissions = lfs.attributes(path, "permissions")
    if permissions and #permissions == 9 then
        local mode = 0
        for i = 1, 9 do
            if permissions:sub(i, i) ~= "-" then mode = mode + 2 ^ (9 - i) end
        end
        -- FAT exposes synthetic permission bits and may reject chmod.
        ffi.C.chmod(temp, mode)
    end
    return withArchive(temp, function(file, archive)
        for name, text in pairs(changes) do
            assert(entryText(file, archive.by_name[name]) == text, "Cannot verify edited ZIP resource")
        end
        return true
    end)
end

return Zip
