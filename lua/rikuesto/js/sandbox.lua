-- argv construction for the JS sandbox. One table per runtime, so adding a
-- runtime never touches the harness or the driver.
--
-- Measured constraints (DESIGN §8.2 / appendix D.2), do not "simplify" them:
--   * node: `--permission` alone breaks sibling `import` with ERR_ACCESS_DENIED,
--     so `--allow-fs-read=<harness dir>` is mandatory.
--   * deno: there is no `--no-net`; deno denies everything by default and the
--     explicit `--deny-*` flags win over any `--allow-*`.
local M = {}

local platform = require('rikuesto.util.platform')

local function js_config()
  local ok, config = pcall(function()
    return require('rikuesto.config').get()
  end)
  if not ok or not config or type(config.js) ~= 'table' then
    return {}
  end
  return config.js
end

--- Directory that holds harness.mjs and shims/ (derived from this file's path).
function M.harness_dir()
  local source = debug.getinfo(1, 'S').source:sub(2)
  local dir = vim.fn.fnamemodify(source, ':p:h'):gsub('\\', '/')
  return dir .. '/harness'
end

function M.harness_path()
  return M.harness_dir() .. '/harness.mjs'
end

local builders = {}

function builders.node(bin, harness_path, cfg)
  local argv = { bin, '--permission', '--allow-fs-read=' .. M.harness_dir() }
  if cfg.allow_net then
    argv[#argv + 1] = '--allow-net'
  end
  if cfg.allow_fs then
    -- The `=*` form is mandatory: a bare `--allow-fs-write` swallows the next
    -- argument, which is the harness path (measured on node 26).
    argv[#argv + 1] = '--allow-fs-write=*'
  end
  argv[#argv + 1] = harness_path
  return argv
end

function builders.deno(bin, harness_path, cfg)
  local argv = { bin, 'run', '--quiet', '--no-prompt' }
  argv[#argv + 1] = cfg.allow_net and '--allow-net' or '--deny-net'
  argv[#argv + 1] = cfg.allow_fs and '--allow-write' or '--deny-write'
  argv[#argv + 1] = '--deny-env'
  argv[#argv + 1] = '--deny-run'
  argv[#argv + 1] = harness_path
  return argv
end

--- argv for `kind` ('node' | 'deno'), or nil when the runtime is unknown or missing.
function M.argv(kind, harness_path)
  local build = builders[kind]
  if not build then
    return nil
  end
  local bin = platform.resolve_tool(kind)
  if not bin then
    return nil
  end
  return build(bin, harness_path or M.harness_path(), js_config())
end

return M
