-- Sandbox round-trip tests for the js subsystem. Every case drives the real
-- harness through `runtime.run` with a hand-built payload, so nothing here
-- depends on the parse/http modules.
local t = require('tests.helper')
local bridge = require('rikuesto.js.bridge')
local platform = require('rikuesto.util.platform')
local runtime = require('rikuesto.js.runtime')
local sandbox = require('rikuesto.js.sandbox')

local TIMEOUT_MS = 20000
local SAMPLE_BODY = '{"ok":true,"items":[1,2]}'

--- Build a payload per DESIGN §8.3; `over` is deep-merged on top.
local function payload(phase, script, over)
  local base = {
    phase = phase,
    script = script,
    meta = { row = 1, col = 0, lang = 'javascript' },
    request = {
      method = 'POST',
      url = 'https://api.example.test/x',
      headers = { { 'Accept', 'application/json' } },
      body = '{"k":1}',
    },
    vars = {},
    globals = {},
    limits = { timeoutMs = 3000 },
  }
  if phase == 'post' then
    base.response = {
      status = 200,
      headers = {
        { 'Content-Type', 'application/json; charset=utf-8' },
        { 'Set-Cookie', 'sid=abc; Path=/' },
      },
      bodyBase64 = bridge.base64_encode(SAMPLE_BODY),
      contentType = { mimeType = 'application/json', charset = 'utf-8' },
      durationMs = 12,
    }
  end
  return vim.tbl_deep_extend('force', base, over or {})
end

local function run(payload_value)
  return runtime.run(payload_value, { timeout_ms = TIMEOUT_MS })
end

--- Run and never return nil, so later assertions still report something useful.
local function must_run(payload_value, label)
  local result, err = run(payload_value)
  if not result then
    print(('      ! %s: %s'):format(label, tostring(err)))
    return {}
  end
  return result
end

t.module('js.runtime')

local kind = runtime.available()
if not kind then
  print('js_spec: no node/deno runtime on this machine - harness cases skipped')
  t.ok(true, 'harness cases skipped (no javascript runtime)')
  t.finish()
  return
end
t.ok(kind == 'node' or kind == 'deno', 'runtime.available() returns node or deno')

local described = runtime.describe()
t.eq(described.runtime, kind, 'runtime.describe() reports the detected runtime')
t.ok(described.bin ~= nil, 'runtime.describe() resolves the binary')
t.eq(described.sandbox, true, 'runtime.describe() reports the sandbox as enabled')

t.finish()

t.module('js.sandbox')

local harness_path = sandbox.harness_path()
t.eq(vim.fn.filereadable(harness_path), 1, 'harness.mjs exists at the resolved path')

local argv = sandbox.argv(kind, harness_path)
t.ok(argv ~= nil, 'sandbox.argv() builds argv for ' .. kind)
t.eq(argv[#argv], harness_path, 'the harness path is the last argument')
if kind == 'node' then
  t.eq(argv[2], '--permission', 'node runs under the permission model')
  t.eq(argv[3], '--allow-fs-read=' .. sandbox.harness_dir(), 'node may read the harness directory')
  t.ok(not vim.tbl_contains(argv, '--allow-net'), 'network stays denied by default')
  t.ok(not vim.tbl_contains(argv, '--allow-fs-write'), 'fs write stays denied by default')
else
  t.eq(argv[2], 'run', 'deno argv invokes a script')
  t.ok(vim.tbl_contains(argv, '--deny-net'), 'deno denies network by default')
  t.ok(vim.tbl_contains(argv, '--deny-write'), 'deno denies fs write by default')
end

local other = kind == 'node' and 'deno' or 'node'
if platform.resolve_tool(other) then
  local other_argv = sandbox.argv(other, harness_path)
  t.ok(other_argv ~= nil, 'sandbox.argv() builds argv for ' .. other)
  t.eq(other_argv[#other_argv], harness_path, other .. ' runs the same harness file')
end

-- config.js.allow_net / allow_fs only add grants; the harness path stays last.
local config = require('rikuesto.config')
config.setup({ js = { allow_net = true, allow_fs = true } })
local granted = sandbox.argv(kind, harness_path)
config.reset()
t.eq(granted[#granted], harness_path, 'granting permissions keeps the harness path last')
if kind == 'node' then
  t.ok(vim.tbl_contains(granted, '--allow-net'), 'node allows network when config.js.allow_net is set')
  t.ok(vim.tbl_contains(granted, '--allow-fs-write=*'), 'node allows fs write when config.js.allow_fs is set')
else
  t.ok(vim.tbl_contains(granted, '--allow-net'), 'deno allows network when config.js.allow_net is set')
  t.ok(vim.tbl_contains(granted, '--allow-write'), 'deno allows fs write when config.js.allow_fs is set')
  t.ok(not vim.tbl_contains(granted, '--deny-net'), 'deno drops --deny-net when network is allowed')
end

t.finish()

t.module('js.harness')

-- 2. pre-request round trip
local pre_result = must_run(payload('pre', "request.variables.set('sig', 'abc')", {
  vars = { existing = 'keep' },
}), 'pre round trip')
t.eq(pre_result.vars and pre_result.vars.sig, 'abc', 'pre: request.variables.set round-trips')
t.eq(pre_result.vars and pre_result.vars.existing, 'keep', 'pre: payload vars are seeded')
t.eq(#(pre_result.errors or {}), 0, 'pre: clean script produces no errors')

-- 3. post round trip: passing and failing client.test
local passing = must_run(payload('post', "client.test('status', () => client.assert(response.status === 200))"),
  'post pass')
t.eq(passing.tests and passing.tests[1] and passing.tests[1].pass, true, 'post: passing client.test is recorded')
t.eq(#(passing.errors or {}), 0, 'post: passing client.test is not an error')

local failing = must_run(
  payload('post', "client.test('status', () => client.assert(response.status === 201, 'want 201'))"), 'post fail')
t.eq(failing.tests and failing.tests[1] and failing.tests[1].pass, false, 'post: failing client.test is recorded')
t.contains(failing.tests and failing.tests[1] and failing.tests[1].message, 'want 201',
  'post: failing client.test keeps the assert message')
t.eq(#(failing.errors or {}), 0, 'post: failing client.test does not raise')

-- 4. crypto shim
local signed = must_run(payload('post', "client.global.set('sig', crypto.hmac.sha256('k', 'x'))"), 'crypto')
t.matches(signed.globals and signed.globals.sig, '^[0-9a-f]+$', 'post: crypto.hmac.sha256 returns hex')
t.eq(#(signed.globals and signed.globals.sig or ''), 64, 'post: crypto.hmac.sha256 returns 64 characters')
t.eq(signed.globals and signed.globals.sig, 'c38edc8815c8489f64738978f44008f8596345545f0baa68ef6fcf5c53e57189',
  'post: crypto.hmac.sha256 matches the reference vector')

-- 5. a throwing script is reported, not fatal
local thrown, thrown_err = run(payload('post', "throw new Error('boom')"))
t.ok(thrown ~= nil, 'throwing script still exits 0 (' .. tostring(thrown_err) .. ')')
t.ok(thrown and #thrown.errors >= 1, 'throwing script returns an error record')
t.contains(thrown and thrown.errors and thrown.errors[1] and thrown.errors[1].message, 'boom',
  'throwing script keeps the error message')

-- 6. sandbox proof: fs write must be blocked, never silently succeed
local probe = vim.fn.tempname() .. '.txt'
local imported, imported_err = run(payload('pre',
  "const fs = await import('node:fs');\n"
  .. "fs.writeFileSync(request.variables.get('probe'), 'x');\n"
  .. "request.variables.set('wrote', 'yes')", {
    vars = { probe = probe },
  }))
t.ok(imported ~= nil, 'blocked fs write still exits 0 (' .. tostring(imported_err) .. ')')
t.ok(imported and imported.vars and imported.vars.wrote ~= 'yes', 'fs write never completes: import(node:fs)')
t.ok(imported and #imported.errors >= 1, 'fs write is reported as an error: import(node:fs)')
t.eq(vim.fn.filereadable(probe), 0, 'fs write created no file: import(node:fs)')

local required = must_run(payload('pre',
  "require('fs').writeFileSync(request.variables.get('probe'), 'x')", {
    vars = { probe = probe .. '.require' },
  }), 'require fs')
t.ok(#required.errors >= 1, "require() is unavailable inside the harness: require('fs')")
t.eq(vim.fn.filereadable(probe .. '.require'), 0, "require('fs') created no file")

-- 7. stdout purity under noisy logging
local noisy = must_run(payload('post',
  "for (let i = 0; i < 40; i += 1) {\n"
  .. "  client.log('line ' + i);\n"
  .. "  console.log('console ' + i);\n"
  .. "}\n"
  .. "client.global.set('done', 'yes')"), 'noisy logging')
t.eq(#(noisy.logs or {}), 80, 'noisy script: every log line is captured')
t.eq(noisy.globals and noisy.globals.done, 'yes', 'noisy script: result still parses')
t.eq(#(noisy.errors or {}), 0, 'noisy script: logging is not an error')

-- fixture round trip: payload vars/globals come back and response is usable
local fixture = bridge.decode(t.fixture_text('js_payload.json'))
t.ok(type(fixture) == 'table', 'fixture js_payload.json parses')
fixture.script = "client.test('json body', () => client.assert(response.body.ok === true));\n"
  .. "client.test('cookie', () => client.assert(response.cookiesByName.sid === 'abc123'));\n"
  .. "client.test('repeated header', () => client.assert(response.headers.valuesOf('x-request-id').length === 2));\n"
  .. "client.test('header value', () => client.assert(response.headers.valueOf('X-Request-Id') === 'r-1'));\n"
  .. "client.global.set('charset', response.contentType.charset)"
local fixture_result = must_run(fixture, 'fixture round trip')
for index = 1, 4 do
  t.eq(fixture_result.tests and fixture_result.tests[index] and fixture_result.tests[index].pass, true,
    ('fixture: test %d passes'):format(index))
end
t.eq(fixture_result.vars and fixture_result.vars.host, 'api.example.test', 'fixture: payload vars round-trip')
t.eq(fixture_result.globals and fixture_result.globals.auth_token, 'seed', 'fixture: payload globals round-trip')
t.eq(fixture_result.globals and fixture_result.globals.charset, 'utf-8', 'fixture: response content type is exposed')

t.finish()

t.module('js.bridge')

t.eq(bridge.encode({ a = 1 }), '{"a":1}', 'encode produces compact json')
local round_trip = bridge.decode(bridge.encode({ k = 'v', n = 2 }))
t.eq(round_trip and round_trip.k, 'v', 'encode/decode round-trips strings')
t.eq(round_trip and round_trip.n, 2, 'encode/decode round-trips numbers')

local bad_json, bad_err = bridge.decode('not json')
t.eq(bad_json, nil, 'decode returns nil for invalid json')
t.ok(type(bad_err) == 'string', 'decode returns an error message for invalid json')

t.eq(bridge.base64_encode('abc'), 'YWJj', 'base64_encode matches the reference encoding')
local raw = 'rikuesto \226\156\147 base64'
t.eq(bridge.base64_decode(bridge.base64_encode(raw)), raw, 'base64 round-trip preserves bytes')

t.finish()
