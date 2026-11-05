-- External formatter processes (`jq` for JSON, `oxfmt` for JS fences).
-- Every call is fail-soft: non-zero exit, empty output or timeout returns `nil, err`
-- so the caller can keep the original fragment verbatim.
local M = {}

local config = require('rikuesto.config')
local platform = require('rikuesto.util.platform')
local util_str = require('rikuesto.util.str')
local log = require('rikuesto.util.log')

local cache = {} -- key = {tool, version, sha256(text)} -> output
local version_cache = {}

local EXTENSIONS = {
    javascript = 'js',
    js = 'js',
    typescript = 'ts',
    ts = 'ts',
    jsx = 'jsx',
    tsx = 'tsx',
    json = 'json',
    jsonc = 'jsonc',
}

local function format_cfg()
    local cfg = config.get()
    return (cfg and cfg.format) or {}
end

local function first_line(text)
    return util_str.short((text or ''):gsub('[\r\n].*$', ''), 200)
end

--- Unresolved tool paths are cached per call site only: `config.setup()` may change them.
local function tool_path(kind)
    local ok, path = pcall(platform.resolve_tool, kind)
    if ok and type(path) == 'string' and path ~= '' then
        return path
    end
    return nil
end

local function tool_version(kind, path)
    if version_cache[kind] then
        return version_cache[kind]
    end
    local version = platform.tool_version({ path, '--version' }) or 'unknown'
    version_cache[kind] = version
    return version
end

--- Some tools report failure as text on stdout instead of a non-zero exit code.
local function looks_like_error(stdout)
    return stdout:match('^%s*ERROR') ~= nil
        or stdout:match('^%s*error:') ~= nil
        or stdout:match('\n%s*ERROR') ~= nil
        or stdout:match('\nerror:') ~= nil
end

--- Spawn `argv` with `text` on stdin and return stdout, or `nil, err`.
local function run(kind, argv, text, opts)
    opts = opts or {}
    local cfg = format_cfg()
    local path = tool_path(kind)
    if not path then
        return nil, kind .. ' not found'
    end

    local full = { path }
    for _, arg in ipairs(argv) do
        full[#full + 1] = arg
    end

    local cache_key
    if cfg.cache ~= false then
        cache_key = kind .. '\0' .. tool_version(kind, path) .. '\0' .. vim.fn.sha256(text)
        local hit = cache[cache_key]
        if hit then
            return hit
        end
    end

    local timeout = opts.timeout_ms or cfg.tool_timeout_ms or 5000
    local ok, result = pcall(function()
        return vim.system(full, { stdin = text, text = true }):wait(timeout)
    end)
    if not ok or not result then
        return nil, kind .. ' could not be started'
    end
    if result.code ~= 0 then
        local detail = result.code == 124 and ('timed out after ' .. timeout .. 'ms')
            or first_line(result.stderr)
        return nil, string.format('%s exited with %d: %s', kind, result.code, detail)
    end

    local stdout = result.stdout or ''
    if util_str.is_blank(stdout) then
        return nil, kind .. ' returned empty output'
    end
    if looks_like_error(stdout) then
        return nil, kind .. ' reported an error: ' .. first_line(stdout)
    end

    if cache_key then
        cache[cache_key] = stdout
    end
    log.debug('format.tools: %s formatted %d bytes', kind, #text)
    return stdout
end

--- `jq --indent <n> .` — strict JSON only, keeps key order and number literals.
function M.jq(text, opts)
    opts = opts or {}
    local indent = opts.indent or format_cfg().indent or 2
    return run('jq', { '--indent', tostring(indent), '.' }, text, opts)
end

--- `oxfmt --stdin-filepath <file>` — JS/TS only; oxfmt collapses JSON, never use it for bodies.
function M.oxfmt(text, filetype, opts)
    opts = opts or {}
    local ext = EXTENSIONS[filetype or 'javascript'] or 'js'
    local filename = opts.filename or ('block.' .. ext)
    return run('oxfmt', { '--stdin-filepath', filename }, text, opts)
end

--- Which external formatters are on PATH (or configured in `config.tools`).
function M.available()
    return {
        jq = tool_path('jq') ~= nil,
        oxfmt = tool_path('oxfmt') ~= nil,
    }
end

return M
