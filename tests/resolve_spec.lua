-- resolve/*: substitution precedence, recursion, cycles, dynamic variables, chain refs (DESIGN §6).
local t = require('tests.helper')
local vars = require('rikuesto.resolve.vars')
local chain = require('rikuesto.resolve.chain')
local dynamic = require('rikuesto.resolve.dynamic')
local pencode = require('rikuesto.resolve.pyencode')

--- Collects scope.report() calls.
local function recorder()
  local events = {}
  local function report(kind, info)
    events[#events + 1] = { kind = kind, info = info or {} }
  end
  return events, report
end

local function kinds(events)
  local out = {}
  for _, event in ipairs(events) do
    out[#out + 1] = event.kind
  end
  return out
end

t.module('resolve.vars')

-- precedence matrix ----------------------------------------------------------
local layered = {
  env = { name = 'env' },
  file = { name = 'file' },
  block = { name = 'block' },
  request = { name = 'request' },
}
t.eq((vars.substitute('{{name}}', layered)), 'request', 'request scope wins')
layered.request = {}
t.eq((vars.substitute('{{name}}', layered)), 'block', 'block scope beats file and env')
layered.block = {}
t.eq((vars.substitute('{{name}}', layered)), 'file', 'file scope beats env')
layered.file = {}
t.eq((vars.substitute('{{name}}', layered)), 'env', 'env is the lowest scope')
layered.env = {}
local scope_events, scope_report = recorder()
layered.report = scope_report
t.eq((vars.substitute('{{name}}', layered)), '{{name}}', 'unresolved placeholder is left verbatim')
t.same(kinds(scope_events), { 'unknown' }, 'unresolved name is reported once')
t.eq(scope_events[1].info.name, 'name', 'report carries the missing name')

local mixed = {
  env = { prefix = 'https://env', token = 'env-token' },
  file = { prefix = 'https://file' },
  block = { path = '/v1/items' },
  report = function() end,
}
t.eq((vars.substitute('{{prefix}}{{path}}?t={{token}}', mixed)), 'https://file/v1/items?t=env-token',
  'each placeholder resolves in its own highest layer')

-- recursion ------------------------------------------------------------------
local recursion_events, recursion_report = recorder()
local recursive = {
  block = { host = '{{scheme}}://{{domain}}', scheme = 'https', domain = 'example.test' },
  report = recursion_report,
}
local text, used = vars.substitute('{{host}}/api', recursive)
t.eq(text, 'https://example.test/api', 'substituted values are expanded recursively')
t.same(used, { 'host', 'scheme', 'domain' }, 'used lists every resolved name in order')
t.same(kinds(recursion_events), {}, 'recursion reports nothing')

-- cycle detection ------------------------------------------------------------
local cycle_events, cycle_report = recorder()
local cyclic = { block = { a = '{{b}}', b = '{{a}}' }, report = cycle_report }
local started = vim.uv.hrtime()
local cycle_text = vars.substitute('{{a}}', cyclic)
local cycle_ms = (vim.uv.hrtime() - started) / 1e6
t.ok(cycle_ms < 500, 'cycle detection returns quickly')
t.contains(cycle_text, '{{', 'cycle leaves a placeholder behind')
t.same(kinds(cycle_events), { 'cycle' }, 'cycle is reported exactly once')
t.ok(cycle_events[1].info.name == 'a' or cycle_events[1].info.name == 'b', 'cycle report names a participant')

local depth_events, depth_report = recorder()
local deep = { block = {}, report = depth_report }
for index = 1, 15 do
  deep.block['v' .. index] = '{{v' .. (index + 1) .. '}}'
end
deep.block.v16 = 'end'
local depth_started = vim.uv.hrtime()
local depth_text = vars.substitute('{{v1}}', deep)
local depth_ms = (vim.uv.hrtime() - depth_started) / 1e6
t.ok(depth_ms < 500, 'a 15-deep chain terminates immediately')
t.contains(depth_text, '{{', 'depth limit stops expansion with a placeholder')
t.ok(#depth_events >= 1 and depth_events[1].kind == 'cycle', 'depth limit is reported as a cycle')

-- percent encoding -----------------------------------------------------------
local encodable = { env = { q = 'a b/c&d=e%41', json = '{"k":"v"}' } }
t.eq((vars.substitute('{{%q}}', encodable)), 'a%20b%2Fc%26d%3De%41', '{{%name}} percent-encodes the value')
t.eq((vars.substitute('{{%json}}', encodable)), '%7B%22k%22%3A%22v%22%7D', '{{%name}} encodes JSON punctuation')
t.eq(pencode.encode('keep-_.~'), 'keep-_.~', 'unreserved characters are untouched')
t.eq(pencode.encode('%2F'), '%2F', 'existing escapes are not double-encoded')
t.eq(pencode.encode('%zz'), '%25zz', 'a stray percent sign is encoded')
t.eq(pencode.encode(nil), '', 'nil encodes to an empty string')
t.eq((vars.substitute('{{ %q }}', encodable)), 'a%20b%2Fc%26d%3De%41', 'placeholder whitespace is ignored')
t.eq((vars.substitute('{{%missing}}', encodable)), '{{%missing}}', 'encoding an unknown name keeps the placeholder')

-- nested object values -------------------------------------------------------
local nested = { env = { cfg = { host = 'nested.example', list = { 'a', 'b' } } }, report = function() end }
t.eq((vars.substitute('{{cfg.host}}', nested)), 'nested.example', 'dot path reads into a nested object')
t.eq((vars.substitute('{{cfg}}', nested)), '{{cfg}}', 'a table value keeps the placeholder')

-- odd input ------------------------------------------------------------------
t.eq((vars.substitute('{{unclosed', {})), '{{unclosed', 'unterminated placeholder is tolerated')
t.eq((vars.substitute('{{}}', {})), '{{}}', 'empty placeholder is tolerated')
t.eq((vars.substitute('', {})), '', 'empty text is tolerated')
t.eq((select(1, vars.substitute(nil, {}))), nil, 'nil text is tolerated')
t.eq((vars.substitute('{{a}}{{a}}', { block = { a = 'x' } })), 'xx', 'repeated placeholders all resolve')
t.eq((vars.substitute('plain text', nil)), 'plain text', 'nil scope is tolerated')

t.finish()

t.module('resolve.chain')

local response = {
  status = 201,
  body = '{"token":"abc123","user":{"id":7,"tags":["x","y"]},"items":[{"id":10},{"id":11}]}',
  json = { token = 'abc123', user = { id = 7, tags = { 'x', 'y' } }, items = { { id = 10 }, { id = 11 } } },
  headers = { { name = 'X-Total', value = '42' }, { name = 'Content-Type', value = 'application/json' } },
}
local named = { login = response }

t.eq(chain.lookup('login.response.status', named), 201, 'status is readable')
t.eq(chain.lookup('login.response.body', named), response.body, 'raw body is readable')
t.eq(chain.lookup('login.response.body.$.token', named), 'abc123', 'JSONPath root key')
t.eq(chain.lookup('login.response.body.$.user.id', named), 7, 'JSONPath nested key')
t.eq(chain.lookup('login.response.body.$.items[0].id', named), 10, 'JSONPath array index is 0-based')
t.eq(chain.lookup('login.response.body.$.items[1].id', named), 11, 'JSONPath second element')
t.eq(chain.lookup('login.response.body.$.user.tags[1]', named), 'y', 'JSONPath index after a nested key')
t.eq(chain.lookup('login.response.body.*', named), response.json, 'body.* returns the decoded body')
t.eq(chain.lookup('login.response.headers.X-Total', named), '42', 'header value is readable')
t.eq(chain.lookup('login.response.headers.x-total', named), '42', 'header lookup is case-insensitive')
t.eq(chain.lookup('login.response.body.$.nope', named), nil, 'missing JSONPath key returns nil')
t.eq(chain.lookup('missing.response.status', named), nil, 'unknown named request returns nil')
t.eq(chain.lookup('login', named), nil, 'a bare name is not a reference')
t.eq(chain.lookup('login.response', named), nil, 'a bare response node is not a value')
t.eq(chain.lookup(nil, named), nil, 'nil expression returns nil')
t.eq(chain.lookup('login.response.status', nil), nil, 'nil response table returns nil')

local decoded_only = { login = { body = '{"token":"decoded"}' } }
t.eq(chain.lookup('login.response.body.$.token', decoded_only), 'decoded', 'body is decoded when json is absent')

local map_headers = { login = { status = 200, headers = { ['X-Trace'] = 'abc' } } }
t.eq(chain.lookup('login.response.headers.x-trace', map_headers), 'abc', 'map-shaped headers are supported')

t.eq(chain.lookup('response.body.token', { response = { body = '{"token":"t"}', json = { token = 't' } } }), 't',
  'assertion form without a request name works')

local chained = {
  chain = named,
  block = { token = 'block-token' },
  request = {},
  report = function() end,
}
t.eq((vars.substitute('Bearer {{login.response.body.$.token}}', chained)), 'Bearer abc123', 'chain beats block values')
t.eq((vars.substitute('{{token}}', chained)), 'block-token', 'plain names still resolve from block')

local request_scope = {
  chain = named,
  block = {},
  request = { token = 'request-token' },
  report = function() end,
}
t.eq((vars.substitute('{{token}}', request_scope)), 'request-token', 'request scope still outranks chain')

local missing_events, missing_report = recorder()
t.eq((vars.substitute('{{gone.response.status}}', { chain = named, report = missing_report })), '{{gone.response.status}}',
  'unknown named request keeps the placeholder')
t.same(kinds(missing_events), { 'unknown' }, 'unknown named request is reported')

t.finish()

t.module('resolve.dynamic')

local dyn_events, dyn_report = recorder()
local dyn = { dynamic = true, report = dyn_report }

t.matches((vars.substitute('{{$uuid}}', dyn)),
  '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$', '$uuid is a v4 UUID')
t.matches((vars.substitute('{{$guid}}', dyn)), '^%x+%-%x+%-%x+%-%x+%-%x+$', '$guid has UUID shape')
t.matches((vars.substitute('{{$timestamp}}', dyn)), '^%d+$', '$timestamp is digits')
t.matches((vars.substitute('{{$isoTimestamp}}', dyn)), '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$',
  '$isoTimestamp is ISO 8601 UTC')
t.matches((vars.substitute('{{$datetime rfc1123}}', dyn)), '^%a%a%a, %d%d %a%a%a %d%d%d%d %d%d:%d%d:%d%d GMT$',
  '$datetime rfc1123')
t.matches((vars.substitute('{{$datetime iso8601}}', dyn)), '^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$',
  '$datetime iso8601')

local now = tonumber((vars.substitute('{{$timestamp}}', dyn)))
local yesterday = tonumber((vars.substitute('{{$timestamp -1 d}}', dyn)))
t.ok(now - yesterday >= 86398 and now - yesterday <= 86402, '$timestamp applies an offset and unit')

local ranged = tonumber((vars.substitute('{{$randomInt 1 5}}', dyn)))
t.ok(ranged >= 1 and ranged <= 5, '$randomInt honours the requested range')
t.matches((vars.substitute('{{$random.integer(3,4)}}', dyn)), '^[34]$', '$random.integer honours family args')
local floating = tonumber((vars.substitute('{{$random.float(1,2)}}', dyn)))
t.ok(floating and floating >= 1 and floating <= 2, '$random.float stays in range')
t.matches((vars.substitute('{{$random.alphabetic(6)}}', dyn)), '^%a%a%a%a%a%a$', '$random.alphabetic(n) letters')
t.matches((vars.substitute('{{$random.alphanumeric(8)}}', dyn)), '^%w%w%w%w%w%w%w%w$',
  '$random.alphanumeric(n) length')
t.matches((vars.substitute('{{$random.hexadecimal(8)}}', dyn)), '^%x%x%x%x%x%x%x%x$',
  '$random.hexadecimal(n) digits')
t.matches((vars.substitute('{{$random.email}}', dyn)), '^[%a]+@[%a]+%.com$', '$random.email shape')

local saved_var = vim.env.RIKUESTO_TEST_VAR
vim.env.RIKUESTO_TEST_VAR = 'from-process'
t.eq((vars.substitute('{{$processEnv RIKUESTO_TEST_VAR}}', dyn)), 'from-process', '$processEnv reads the environment')
t.eq((vars.substitute('{{$env.RIKUESTO_TEST_VAR}}', dyn)), 'from-process', '$env.NAME reads the environment')
vim.env.RIKUESTO_TEST_VAR = saved_var

t.eq((vars.substitute('{{$projectRoot}}', dyn)), vim.fn.getcwd(), '$projectRoot resolves to the working directory')

t.same(kinds(dyn_events), {}, 'supported dynamic variables report nothing')

local unknown_events, unknown_report = recorder()
t.eq((vars.substitute('{{$nope}}', { dynamic = true, report = unknown_report })), '{{$nope}}',
  'unknown dynamic variable keeps the placeholder')
t.same(kinds(unknown_events), { 'unknown' }, 'unknown dynamic variable is reported')

local disabled_events, disabled_report = recorder()
t.eq((vars.substitute('{{$uuid}}', { report = disabled_report })), '{{$uuid}}',
  'dynamic expansion is off unless scope.dynamic is set')
t.same(kinds(disabled_events), { 'unknown' }, 'disabled dynamic variable is reported as unknown')

t.eq(dynamic.expand('$nope'), nil, 'dynamic.expand returns nil for unknown names')
t.eq(dynamic.expand('$randomInt', { '7', '7' }), '7', 'dynamic.expand accepts a token list')
t.matches(dynamic.expand('$uuid'), '^%x+%-%x+%-%x+%-%x+%-%x+$', 'dynamic.expand is callable directly')
local names = dynamic.names()
t.ok(#names >= 12, 'dynamic.names lists the supported variables')

local seen = {}
for _, name in ipairs(names) do
  seen[name:lower()] = true
end
for _, expected in ipairs({ '$uuid', '$guid', '$timestamp', '$isotimestamp', '$datetime', '$randomint' }) do
  t.ok(seen[expected] or seen[expected:lower()], ('dynamic.names contains %s'):format(expected))
end

t.finish()
