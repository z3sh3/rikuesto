-- :checkhealth rikuesto
local M = {}

local function version_tuple(text)
  local major, minor, patch = (text or ''):match('(%d+)%.(%d+)%.?(%d*)')
  return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

function M.check()
  local health = vim.health
  health.start('rikuesto')

  local platform = require('rikuesto.util.platform')
  local config = require('rikuesto.config').get()

  -- curl (required)
  local curl = config.tools.curl or platform.resolve_tool('curl')
  if not curl then
    health.error('curl not found', { 'Install curl or set tools.curl in setup()' })
  else
    local version = platform.tool_version({ curl, '--version' })
    local major, minor = version_tuple(version)
    health.ok(('curl: %s'):format(version or 'unknown'))
    if major > 7 or (major == 7 and minor >= 70) then
      health.ok('curl supports --write-out %{json} (>= 7.70)')
    else
      health.warn('curl < 7.70: response metadata will use the header-dump fallback',
        { 'Upgrade curl for exact timings' })
    end
  end

  -- JSON / JS formatters (optional)
  local tools = require('rikuesto.format.tools')
  local available = tools.available()
  if available.jq then
    health.ok(('jq: %s'):format(platform.tool_version({ platform.resolve_tool('jq'), '--version' }) or 'found'))
  else
    health.info('jq not found: JSON bodies use the built-in ordered printer')
  end
  if available.oxfmt then
    health.ok(('oxfmt: %s'):format(platform.tool_version({ platform.resolve_tool('oxfmt'), '--version' })
      or 'found'))
  else
    health.info('oxfmt not found: JS script blocks will not be formatted')
  end

  -- JS runtime (optional)
  local ok_runtime, runtime = pcall(require, 'rikuesto.js.runtime')
  if ok_runtime then
    local info = runtime.describe()
    if info.runtime then
      health.ok(('JS runtime: %s %s'):format(info.runtime, info.version or ''))
    else
      health.info('no JS runtime (node/deno): pre-request and response scripts are skipped')
    end
  else
    health.warn('js runtime module failed to load: ' .. tostring(runtime))
  end

  -- treesitter http parser (optional, display only)
  local has_parser = pcall(vim.treesitter.language.add, 'http')
  if has_parser then
    health.ok('treesitter http parser available (highlighting/folding)')
  else
    health.info('treesitter http parser missing: highlighting is degraded, requests still work')
  end

  -- env.json
  local ok_env, env = pcall(require, 'rikuesto.env.api')
  if not ok_env then
    health.warn('env module failed to load: ' .. tostring(env))
  else
    local path = env.path()
    if not path then
      health.warn('env path unresolved')
    elseif vim.fn.filereadable(path) == 0 then
      health.info(('env file not found: %s'):format(path))
    else
      local active = env.active()
      if active then
        local count = 0
        for _ in pairs(env.variables()) do
          count = count + 1
        end
        health.ok(('env: %s (profile %s, %d variables)'):format(path, active, count))
      else
        health.warn(('env file has no active profile: %s'):format(path))
      end
    end
  end

  -- parse smoke test
  local ok_parse, block = pcall(require, 'rikuesto.parse.block')
  if ok_parse then
    local ok, result = pcall(block.parse, { 'GET https://example.com', '', '###', 'POST https://example.com',
      'Content-Type: application/json', '', '{"a":1}' })
    if ok and result and #result.requests == 2 then
      health.ok('parser smoke test passed')
    else
      health.error('parser smoke test failed')
    end
  else
    health.error('parse module failed to load: ' .. tostring(block))
  end
end

return M
