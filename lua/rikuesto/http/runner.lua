-- Asynchronous curl execution (DESIGN §7.1/§7.3): payload temp files in, Response out.
-- Everything runs off the event loop; `job:cancel()` kills the child process.
local response = require('rikuesto.http.response')

local M = {}

local DEFAULT_MAX_TIME_MS = 30000
local TIMEOUT_GRACE_MS = 5000

local function dirname(path)
    return (path:gsub('[/\\][^/\\]*$', ''))
end

local function ensure_dir(path)
    if type(path) == 'string' and path ~= '' and vim.fn.isdirectory(path) == 0 then
        vim.fn.mkdir(path, 'p')
    end
    return path
end

--- Byte-exact write: payloads must never be re-encoded by vim.json / line ending rules.
--- libuv has no text mode, so `w` already writes the bytes unchanged.
local function write_file(path, text)
    ensure_dir(dirname(path))
    local fd, open_err = vim.uv.fs_open(path, 'w', 420)
    if not fd then
        return nil, open_err
    end
    if type(text) == 'string' and text ~= '' then
        local written, write_err = vim.uv.fs_write(fd, text, -1)
        if not written then
            vim.uv.fs_close(fd)
            return nil, write_err
        end
    end
    vim.uv.fs_close(fd)
    return true
end

local function safe_config()
    local ok, cfg = pcall(function()
        return require('rikuesto.config').get()
    end)
    if ok and type(cfg) == 'table' then
        return cfg
    end
    return {}
end

local function paths_of(spec)
    local paths = {}
    for _, file in ipairs(spec.temp_files or {}) do
        if file.kind == 'headers' then
            paths.headers = file.path
        elseif file.kind == 'output' then
            paths.body = file.path
        elseif file.kind == 'writeout' then
            paths.writeout = file.path
        end
    end
    return paths
end

--- Removes the scratch files; `keep` leaves every path in place (log points at them).
local function cleanup(spec, keep)
    local dirs = {}
    for _, file in ipairs(spec.temp_files or {}) do
        local dir = dirname(file.path)
        if dir ~= '' then
            dirs[dir] = true
        end
        if not keep then
            pcall(vim.fn.delete, file.path)
        end
    end
    if keep then
        return
    end
    for dir in pairs(dirs) do
        -- plain 'd' only removes an empty directory, so a caller-supplied tmpdir survives
        pcall(vim.fn.delete, dir, 'd')
    end
end

--- @param spec table result of `curl.build`
--- @param ctx table curl context (may repeat `spec.meta.ctx`)
--- @param on_done fun(response: table, err: string|nil)
--- @return table job
function M.run(spec, ctx, on_done)
    spec = spec or { argv = {}, temp_files = {} }
    ctx = ctx or {}
    on_done = on_done or function() end
    local cfg = safe_config()

    local job = { done = false, handle = nil, cancelled = false }
    local finished = false

    local function finish(result, err)
        if finished then
            return
        end
        finished = true
        job.done = true
        job.handle = nil
        on_done(result, err)
    end

    function job:cancel()
        self.cancelled = true
        local active = self.handle
        if active and not finished then
            pcall(active.kill, active, 'sigterm')
        end
    end

    for _, file in ipairs(spec.temp_files or {}) do
        if file.text ~= nil then
            local ok, err = write_file(file.path, file.text)
            if not ok then
                cleanup(spec)
                vim.schedule(function()
                    finish(nil, ('cannot write %s: %s'):format(file.path, tostring(err)))
                end)
                return job
            end
        end
    end

    local paths = paths_of(spec)
    local max_time_ms = ctx.max_time_ms or (cfg.curl and cfg.curl.max_time_ms) or DEFAULT_MAX_TIME_MS

    local ok_spawn, handle = pcall(vim.system, spec.argv, {
        text = true,
        timeout = max_time_ms + TIMEOUT_GRACE_MS,
    }, function(obj)
        -- vim.system callbacks run in a libuv fast event: nothing here may call vim.fn,
        -- and callers open windows from on_done, so hop back to the main loop first.
        vim.schedule(function()
            job.handle = nil
            -- obj.signal is 0 (not nil) for a normal exit; non-zero means we killed it.
            local killed = obj.signal ~= nil and obj.signal ~= 0
            local meta = {
                exit_code = obj.code,
                signal = obj.signal,
                stderr = obj.stderr,
                url = spec.meta and spec.meta.url or nil,
                method = spec.meta and spec.meta.method or nil,
                max_bytes = ctx.max_bytes
                    or (cfg.ui and cfg.ui.response and cfg.ui.response.max_bytes)
                    or nil,
                timed_out = killed and not job.cancelled,
                cancelled = job.cancelled,
            }
            -- `-w '%{json}'` lands on stdout; park it next to the other scratch files so
            -- response.parse only ever reads paths.
            if paths.writeout then
                write_file(paths.writeout, obj.stdout or '')
            end
            local result = response.parse(paths, meta)
            local keep = ctx.keep_temp_on_error
            if keep == nil then
                keep = cfg.curl and cfg.curl.keep_temp_on_error
            end
            if keep and result.error then
                cleanup(spec, true)
                local ok_log, log = pcall(require, 'rikuesto.util.log')
                if ok_log then
                    for _, file in ipairs(spec.temp_files or {}) do
                        log.info('kept temp file %s', file.path)
                    end
                end
            else
                cleanup(spec)
            end
            finish(result, result.error and result.error.message or nil)
        end)
    end)

    if not ok_spawn then
        cleanup(spec)
        vim.schedule(function()
            finish(nil, tostring(handle))
        end)
        return job
    end
    job.handle = handle
    return job
end

return M
