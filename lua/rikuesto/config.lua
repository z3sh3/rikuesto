-- Single source of truth for runtime options. `setup()` deep-merges user opts.
local M = {}

M.defaults = {
  env = {
    path = nil, -- nil -> %LOCALAPPDATA%/nvim/rikuesto/env.json (see env/file.lua)
    profile = nil, -- nil -> env.json global.env
    project_local = false,
  },
  tools = {
    curl = nil,
    jq = nil,
    oxfmt = nil,
  },
  curl = {
    bin = nil,
    extra_args = {},
    insecure = false,
    proxy = nil,
    follow_redirects = true,
    max_time_ms = 30000,
    inline_body_max = 8000,
    body_tempdir = nil,
    keep_temp_on_error = false,
    trim_body_trailing_newline = false,
  },
  js = {
    runtime = 'auto', -- auto (node first) | node | deno | none
    timeout_ms = 3000,
    allow_net = false,
    allow_fs = false,
    response_handlers = true,
    pre_request_scripts = true,
  },
  format = {
    enabled = true,
    json = 'auto', -- auto (jq -> internal) | jq | internal
    js = 'auto', -- auto (oxfmt) | oxfmt | none
    tool_timeout_ms = 5000,
    cache = true,
    explode_query = 'keep',
    sort_headers = false,
    align_variables = true,
    indent = 2,
  },
  curl_export = {
    dialect = 'native', -- native | pwsh | sh | cmd
    register = '+',
    mask_secrets = true,
    inline_body_max = 2000,
  },
  ui = {
    response = {
      layout = 'split', -- split | botright | float
      size = 0.4,
      open = 'auto', -- auto | always | never
      max_bytes = 2097152,
    },
    extmark = { enabled = true },
    statusline = { enabled = true },
  },
  -- Defaults are OFF: the plugin installs no shortcuts unless you opt in,
  -- either with `keymaps = true` (full default set, local-leader prefixed) or a
  -- table such as `keymaps = { rr = '<Space>r', rc = '<Space>c' }` (only those keys).
  keymaps = false,
  -- Temporary buffer-local mapping installed only while a request is in flight.
  -- Set to `false` to rely on :Rikuesto cancel alone.
  cancel_key = '<C-c>',
  mask_patterns = { 'token', 'secret', 'password', 'authorization', 'cookie', 'api_key' },
  log = { level = 'warn', keep = 500 },
}

local current = vim.deepcopy(M.defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  return current
end

function M.get()
  return current
end

function M.reset()
  current = vim.deepcopy(M.defaults)
  return current
end

--- Render the effective config for :checkhealth / debugging (secrets masked).
function M.describe()
  local copy = vim.deepcopy(current)
  return copy
end

return M
