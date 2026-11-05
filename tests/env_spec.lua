-- env/*: path resolution, schema normalisation, profile merge, mtime cache (DESIGN §10).
local t = require('tests.helper')
local config = require('rikuesto.config')
local platform = require('rikuesto.util.platform')
local env_file = require('rikuesto.env.file')
local env_api = require('rikuesto.env.api')

local function write_text(path, text)
  local fd = assert(io.open(path, 'wb'))
  fd:write(text)
  fd:close()
end

--- Temp env.json holding `text`; returns its path.
local function temp_env(text)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/env.json'
  write_text(path, text)
  return path
end

t.module('env.file')

local basic = t.fixture_text('env_basic.json')

-- schema ---------------------------------------------------------------------
local doc = env_file.parse(basic, '/virtual/env.json')
t.ok(doc.ok, 'fixture parses')
t.eq(doc.active, 'dev', 'global.env is the default profile')
t.eq(doc.global_var.api_key, 'global-key', 'global.var is loaded')
t.eq(doc.global_var.port, '8080', 'numbers are stringified')
t.eq(doc.global_var.debug, 'true', 'booleans are stringified')
t.eq(doc.profiles.dev.api_key, 'dev-key', 'profile section is normalised')
t.eq(doc.profiles.prod.dev_host, 'https://prod', 'second profile is normalised')
t.same(doc.defaults, { timeout = 30000, follow_redirects = true }, 'global.defaults is exposed')

-- path priority --------------------------------------------------------------
config.setup({})
local saved_env = vim.env.RIKUESTO_ENV
local tmp_path = temp_env(basic)

vim.env.RIKUESTO_ENV = tmp_path
t.eq(env_file.resolve_path(nil), tmp_path, '$RIKUESTO_ENV is used when no override exists')
t.eq(env_file.resolve_path('/explicit/config.json'), '/explicit/config.json', 'explicit argument wins')
config.setup({ env = { path = tmp_path } })
t.eq(env_file.resolve_path(nil), tmp_path, 'setup().env.path wins over $RIKUESTO_ENV')
config.setup({})

vim.env.RIKUESTO_ENV = nil
t.matches(env_file.resolve_path(nil), 'env%.json$', 'default path always ends with env.json')
if platform.is_windows then
  t.eq(env_file.resolve_path(nil), vim.fs.joinpath(vim.env.LOCALAPPDATA, 'nvim', 'rikuesto', 'env.json'),
    'default path is %LOCALAPPDATA%/nvim/rikuesto/env.json')
else
  t.matches(env_file.resolve_path(nil), 'nvim/rikuesto/env%.json$', 'default path ends with nvim/rikuesto/env.json')
end

-- broken file ----------------------------------------------------------------
config.setup({})
local broken = env_file.parse(t.fixture_text('env_broken.json'), '/virtual/broken.json')
t.eq(broken.ok, false, 'broken JSON is not ok')
t.ok(#broken.diagnostics > 0, 'broken JSON yields diagnostics')
t.eq(broken.diagnostics[1].code, 'env.json', 'diagnostic code names the JSON decoder')
t.eq(broken.diagnostics[1].severity, 'error', 'broken JSON is an error diagnostic')
t.matches(broken.diagnostics[1].message, '^cannot parse env file: .+', 'diagnostic carries the decoder message')
t.eq(broken.active, nil, 'broken JSON exposes no active profile')
t.eq(next(broken.global_var), nil, 'broken JSON exposes empty global.var')
t.eq(next(broken.profiles), nil, 'broken JSON exposes no profiles')

local missing = env_file.load('/nonexistent/rikuesto/env.json')
t.eq(missing.ok, false, 'missing file is not ok')
t.eq(missing.diagnostics[1].code, 'env.missing', 'missing file is reported')

-- cache ----------------------------------------------------------------------
local cache_path = temp_env(basic)
local first = env_file.load(cache_path)
t.eq(first.global_var.api_key, 'global-key', 'file.load reads the document')
local stamp = os.time() + 20
write_text(cache_path, (basic:gsub('global%-key', 'fresh-key')))
vim.uv.fs_utime(cache_path, stamp, stamp)
local second = env_file.load(cache_path)
t.eq(second.global_var.api_key, 'fresh-key', 'mtime change invalidates the cache')
t.ok(env_file.load(cache_path) == second, 'unchanged mtime returns the cached document')
env_file.invalidate()
t.ok(env_file.load(cache_path) ~= second, 'invalidate() forces a re-read')

t.finish()

t.module('env.api')

local api_path = temp_env(basic)
config.setup({ env = { path = api_path } })
env_api.reload()

t.eq(env_api.path(), api_path, 'api.path follows setup().env.path')
t.eq(env_api.active(), 'dev', 'api.active defaults to global.env')
t.same(env_api.list(), { 'dev', 'prod' }, 'api.list is sorted')

-- merge ----------------------------------------------------------------------
local vars = env_api.variables()
t.eq(vars.api_key, 'dev-key', 'active profile overrides global.var')
t.eq(vars.test_host, 'http://demo', 'global.var survives when the profile does not override it')
t.eq(vars.dev_host, 'https://dev', 'profile-only variable is present')
t.eq(vars.debug, 'true', 'merged values are strings')
t.eq(type(vars.cfg), 'table', 'nested object is tolerated by variables()')
t.eq(env_api.get('api_key'), 'dev-key', 'api.get returns the merged value')
t.eq(env_api.get('nope'), nil, 'api.get returns nil for unknown names')
t.same(env_api.defaults(), { timeout = 30000, follow_redirects = true }, 'api.defaults returns global.defaults')

-- configured profile ---------------------------------------------------------
config.setup({ env = { path = api_path, profile = 'prod' } })
env_api.reload()
t.eq(env_api.active(), 'prod', 'setup().env.profile overrides global.env')
t.eq(env_api.variables().api_key, 'prod-key', 'configured profile drives the merge')

-- switch ---------------------------------------------------------------------
config.setup({ env = { path = api_path } })
env_api.reload()
t.eq(env_api.active(), 'dev', 'reload returns to global.env')

local switched_ok, switched_err = env_api.switch('prod')
t.ok(switched_ok, 'switch to a known profile succeeds')
t.eq(switched_err, nil, 'successful switch has no error')
t.eq(env_api.active(), 'prod', 'switch changes the in-memory profile')
t.eq(env_api.variables().api_key, 'prod-key', 'variables follow the switched profile')

env_api.reload()
t.eq(env_api.active(), 'prod', 'reload keeps a profile that still exists')

local bad_ok, bad_err = env_api.switch('staging')
t.eq(bad_ok, nil, 'switch to an unknown profile fails')
t.contains(bad_err or '', 'staging', 'error names the unknown profile')
t.contains(bad_err or '', 'dev', 'error lists the available profiles')
t.eq(env_api.active(), 'prod', 'failed switch keeps the previous profile')

local nil_ok, nil_err = env_api.switch(nil)
t.eq(nil_ok, nil, 'switch(nil) fails')
t.contains(nil_err or '', 'required', 'switch(nil) explains what is missing')

-- mtime reload ---------------------------------------------------------------
local live_path = temp_env(basic)
config.setup({ env = { path = live_path } })
env_api.reload()
t.eq(env_api.get('api_key'), 'dev-key', 'live file is read')

local live_stamp = os.time() + 40
write_text(live_path, (basic:gsub('dev%-key', 'dev-key-v2')))
vim.uv.fs_utime(live_path, live_stamp, live_stamp)
t.eq(env_api.get('api_key'), 'dev-key-v2', 'mtime change is picked up without an explicit reload')

write_text(live_path, (basic:gsub('dev%-key', 'dev-key-v3')))
vim.uv.fs_utime(live_path, live_stamp, live_stamp)
t.eq(env_api.get('api_key'), 'dev-key-v2', 'unchanged mtime keeps using the cache')
env_api.reload()
t.eq(env_api.get('api_key'), 'dev-key-v3', 'api.reload() forces a re-read')

-- broken file through the API ------------------------------------------------
config.setup({ env = { path = temp_env(t.fixture_text('env_broken.json')) } })
env_api.reload()
t.same(env_api.variables(), {}, 'broken file yields an empty variable table')
t.eq(env_api.active(), nil, 'broken file has no active profile')
local broken_ok, broken_err = env_api.switch('dev')
t.eq(broken_ok, nil, 'switch cannot succeed against a broken file')
t.contains(broken_err or '', 'dev', 'switch error names the requested profile')

vim.env.RIKUESTO_ENV = saved_env
config.setup({})

t.finish()
