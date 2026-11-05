-- Runtime detection and synchronous harness execution.
-- JS runs only around a request (pre-request script, response handler), never on
-- a hot path, so `vim.system(...):wait()` is acceptable here.
local M = {}

local bridge = require('rikuesto.js.bridge')
local sandbox = require('rikuesto.js.sandbox')
local platform = require('rikuesto.util.platform')
local log = require('rikuesto.util.log')

--- Preference order for `config.js.runtime == 'auto'` (DESIGN §8.2).
local RUNTIMES = { 'node', 'deno' }
local DEFAULT_TIMEOUT_MS = 3000

local function js_config()
  local ok, config = pcall(function()
    return require('rikuesto.config').get()
  end)
  if not ok or not config or type(config.js) ~= 'table' then
    return {}
  end
  return config.js
end

--- 'node' | 'deno' | nil, honouring `config.js.runtime`.
function M.available()
  local wanted = js_config().runtime or 'auto'
  if wanted == 'none' then
    return nil
  end
  if wanted ~= 'auto' then
    for _, kind in ipairs(RUNTIMES) do
      if kind == wanted then
        return platform.resolve_tool(kind) and kind or nil
      end
    end
    return nil
  end
  for _, kind in ipairs(RUNTIMES) do
    if platform.resolve_tool(kind) then
      return kind
    end
  end
  return nil
end

local function failure_message(kind, result, timeout_ms)
  local stderr = (result.stderr or ''):gsub('%s+$', '')
  if stderr ~= '' then
    return stderr
  end
  if result.code == 124 or result.signal ~= nil then
    return ('%s sandbox timed out after %dms'):format(kind, timeout_ms)
  end
  local stdout = (result.stdout or ''):gsub('%s+$', '')
  return ('%s sandbox exited with code %d: %s'):format(kind, result.code or -1, stdout)
end

--- Run one harness payload synchronously. Returns result|nil, err.
--- opts = { timeout_ms = number }
function M.run(payload, opts)
  opts = opts or {}
  local kind = M.available()
  if not kind then
    return nil, 'no javascript runtime found (install node or deno)'
  end
  local argv = sandbox.argv(kind, sandbox.harness_path())
  if not argv then
    return nil, ('unsupported javascript runtime: %s'):format(tostring(kind))
  end
  local stdin, encode_err = bridge.encode(payload or {})
  if not stdin then
    return nil, encode_err
  end
  local timeout_ms = opts.timeout_ms or js_config().timeout_ms or DEFAULT_TIMEOUT_MS
  local ok, result = pcall(function()
    return vim.system(argv, { stdin = stdin, text = true, timeout = timeout_ms }):wait()
  end)
  if not ok then
    return nil, ('failed to start %s: %s'):format(kind, tostring(result))
  end
  if result.code ~= 0 then
    return nil, failure_message(kind, result, timeout_ms)
  end
  local stdout = (result.stdout or ''):gsub('%s+$', '')
  local decoded = bridge.decode(stdout)
  if type(decoded) ~= 'table' then
    return nil, ('harness returned non-JSON: %s'):format(result.stdout or '')
  end
  if type(decoded.logs) == 'table' then
    for _, line in ipairs(decoded.logs) do
      log.debug('js: %s', tostring(line))
    end
  end
  return decoded
end

--- { runtime, bin, version, sandbox } for :checkhealth / debugging.
function M.describe()
  local kind = M.available()
  if not kind then
    return { runtime = nil, bin = nil, version = nil, sandbox = false }
  end
  local bin = platform.resolve_tool(kind)
  return {
    runtime = kind,
    bin = bin,
    version = platform.tool_version({ bin, '--version' }),
    sandbox = true,
  }
end

return M
