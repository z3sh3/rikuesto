-- Builds the curl argv for one resolved request (DESIGN §7.2/§7.3).
-- Pure: no process is spawned and no payload byte is written here. Only the scratch
-- directory is created so that the `-D`/`-o` targets exist; `runner` fills the payload.
local str = require('rikuesto.util.str')
local auth = require('rikuesto.http.auth')

local M = {}

local DEFAULT_INLINE_BODY_MAX = 8000
local PAYLOAD_NAME = 'payload.bin'

local function join(dir, name)
    return (dir:gsub('[/\\]+$', '')) .. '/' .. name
end

local function ensure_dir(path)
    if vim.fn.isdirectory(path) == 0 then
        vim.fn.mkdir(path, 'p')
    end
    return path
end

local function scratch_dir(ctx)
    local dir = ctx.tmpdir
    if type(dir) ~= 'string' or dir == '' then
        dir = vim.fn.tempname()
    end
    return ensure_dir(dir)
end

local function ceil_seconds(ms)
    local seconds = math.ceil(ms / 1000)
    if seconds < 1 then
        seconds = 1
    end
    return tostring(seconds)
end

--- Body kind that actually sends payload, or nil for "no body".
local function body_kind(req)
    local body = req.body
    if type(body) ~= 'table' then
        return nil
    end
    if body.kind == nil or body.kind == 'none' then
        return nil
    end
    return body.kind
end

--- `.http` files write urlencoded bodies one `key=value` per line; curl wants one string.
local function urlencoded_text(text)
    local parts = {}
    for _, line in ipairs(str.lines(text)) do
        local piece = str.trim(line)
        if piece ~= '' then
            parts[#parts + 1] = piece
        end
    end
    return table.concat(parts, '&')
end

local function multipart_parts(text)
    local parts = {}
    for _, line in ipairs(str.lines(text)) do
        if not str.is_blank(line) then
            parts[#parts + 1] = str.trim(line)
        end
    end
    return parts
end

local function append_body(spec, req, ctx, dir)
    local kind = body_kind(req)
    if kind == nil then
        return
    end
    local argv = spec.argv
    if kind == 'multipart' then
        for _, part in ipairs(multipart_parts(req.body.text or '')) do
            argv[#argv + 1] = '-F'
            argv[#argv + 1] = part
        end
        return
    end
    if kind == 'external' then
        local file = req.body.file
        if type(file) ~= 'string' or file == '' then
            return -- nothing to upload; do not point curl at the current directory
        end
        argv[#argv + 1] = '--data-binary'
        argv[#argv + 1] = '@' .. vim.fn.fnamemodify(file, ':p')
        return
    end
    -- raw | json | xml | graphql | urlencoded
    local text = req.body.text or ''
    if kind == 'urlencoded' then
        text = urlencoded_text(text)
    end
    if #text <= (ctx.inline_body_max or DEFAULT_INLINE_BODY_MAX) then
        spec.meta.inline_body = true
        argv[#argv + 1] = '--data-raw'
        argv[#argv + 1] = text
        return
    end
    local payload_dir = dir
    if type(ctx.body_tempdir) == 'string' and ctx.body_tempdir ~= '' then
        payload_dir = ensure_dir(ctx.body_tempdir)
    end
    local path = join(payload_dir, PAYLOAD_NAME)
    argv[#argv + 1] = '--data-binary'
    argv[#argv + 1] = '@' .. path
    -- `text` is handed to runner, which writes the bytes verbatim (no re-encoding).
    spec.temp_files[#spec.temp_files + 1] = { path = path, kind = 'body', text = text }
end

--- @param req table Request with variables already resolved
--- @param ctx table { curl_bin, extra_args, follow_redirects, insecure, proxy, max_time_ms,
---                     inline_body_max, tmpdir, body_tempdir }
--- @return { argv = string[], temp_files = table[], meta = table }
function M.build(req, ctx)
    req = req or {}
    ctx = ctx or {}
    local meta = req.meta or {}
    local dir = scratch_dir(ctx)

    local spec = {
        argv = {},
        temp_files = {},
        meta = { inline_body = false, method = 'GET', has_body = false, url = '' },
    }
    local argv = spec.argv

    local headers_path = join(dir, 'headers.txt')
    local body_path = join(dir, 'body.bin')
    local writeout_path = join(dir, 'writeout.json')
    spec.temp_files[#spec.temp_files + 1] = { path = headers_path, kind = 'headers' }
    spec.temp_files[#spec.temp_files + 1] = { path = body_path, kind = 'output' }
    spec.temp_files[#spec.temp_files + 1] = { path = writeout_path, kind = 'writeout' }

    argv[#argv + 1] = ctx.curl_bin or 'curl'
    for _, extra in ipairs(ctx.extra_args or {}) do
        argv[#argv + 1] = tostring(extra)
    end
    argv[#argv + 1] = '-sS'
    argv[#argv + 1] = '--no-progress-meter'
    argv[#argv + 1] = '-D'
    argv[#argv + 1] = headers_path
    argv[#argv + 1] = '-o'
    argv[#argv + 1] = body_path
    argv[#argv + 1] = '-w'
    argv[#argv + 1] = '%{json}'

    local method = string.upper(req.method or 'GET')
    spec.meta.method = method
    spec.meta.has_body = body_kind(req) ~= nil
    if method == 'HEAD' then
        -- `-X HEAD` makes curl wait for a body that never arrives (verified: exit 28 on
        -- --max-time); --head is the only correct way to issue a HEAD request.
        argv[#argv + 1] = '--head'
    elseif spec.meta.has_body or method ~= 'GET' then
        argv[#argv + 1] = '-X'
        argv[#argv + 1] = method
    end

    if req.http_version == 'HTTP/2' then
        argv[#argv + 1] = '--http2'
    elseif req.http_version == 'HTTP/1.1' then
        argv[#argv + 1] = '--http1.1'
    end

    if ctx.follow_redirects ~= false and not meta.no_redirect then
        argv[#argv + 1] = '-L'
    end
    if ctx.insecure or meta.insecure then
        argv[#argv + 1] = '-k'
    end
    local proxy = meta.proxy or ctx.proxy
    if type(proxy) == 'string' and proxy ~= '' then
        argv[#argv + 1] = '--proxy'
        argv[#argv + 1] = proxy
    end
    local timeout_ms = meta.timeout_ms or ctx.max_time_ms
    if type(timeout_ms) == 'number' and timeout_ms > 0 then
        argv[#argv + 1] = '--max-time'
        argv[#argv + 1] = ceil_seconds(timeout_ms)
    end

    local headers = req.headers or {}
    local url = req.url or ''
    local has_authorization = false
    for _, header in ipairs(headers) do
        if string.lower(header.name or '') == 'authorization' then
            has_authorization = true
        end
    end
    if not has_authorization then
        local credentials = auth.from_url(url)
        if credentials then
            url = credentials.clean_url
            argv[#argv + 1] = '-u'
            argv[#argv + 1] = credentials.pass and (credentials.user .. ':' .. credentials.pass)
                or credentials.user
        end
    end

    for _, header in ipairs(headers) do
        argv[#argv + 1] = '-H'
        argv[#argv + 1] = (header.name or '') .. ': ' .. (header.value or '')
    end

    append_body(spec, req, ctx, dir)

    argv[#argv + 1] = url
    spec.meta.url = url
    return spec
end

return M
