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
    -- `auto` = the platform shell (pwsh on Windows, sh elsewhere), so the copy is a
    -- command that can be pasted and run. `native` is the non-executable one-arg-per-line
    -- listing (useful as a reference only).
    dialect = 'auto', -- auto | pwsh | sh | cmd | native
    register = '+',
    -- Off: a copy is the user's own request, and `***` values make it unrunnable.
    -- Turn it on when the copy leaves the machine (chat, issue, shared terminal).
    mask_secrets = false,
  },
  ui = {
    response = {
      layout = 'right', -- right | bottom | top | left | float (vsplit -> right, split/botright -> bottom)
      size = 0.5,
      open = 'auto', -- auto | always | never
      -- Initial view of the response buffer: all | header | body | script. H/B/S/A switch
      -- inside the buffer, J/K walk the same order; the last choice sticks for the session.
      view = 'all',
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
