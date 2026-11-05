-- Probe: real integration path — jq / oxfmt with stdin via vim.system on Windows.
local function run(argv, input)
  local res = vim.system(argv, { stdin = input, text = true }):wait(20000)
  return res
end

local json = '{\n  "b": 1,\n  "a": {"z": [1,2]},\n  "big": 1234567890123456789\n}\n'
local r = run({ 'jq', '--indent', '2', '.' }, json)
print(('[jq] code=%d\n%s'):format(r.code, r.stdout or r.stderr))

local js = 'const a={b:1,c:[1,2]}\nfunction f( ){return a}\nif(a.b){console.log("x")}\n'
local r2 = run({ 'oxfmt', '--stdin-filepath', 'block.js' }, js)
print(('[oxfmt] code=%d\n%s'):format(r2.code, r2.stdout or r2.stderr))

-- fragment that is not a valid module on its own (top-level await/return)
local frag = 'return response.status === 200;\n'
local r3 = run({ 'oxfmt', '--stdin-filepath', 'block.js' }, frag)
print(('[oxfmt fragment] code=%d out=%q err=%q'):format(r3.code, r3.stdout or '', (r3.stderr or ''):sub(1, 120)))

-- utf-8 payload round trip
local cn = '{"msg":"中文 test ✓"}'
local r4 = run({ 'jq', '.' }, cn)
print(('[jq utf8] code=%d out=%s'):format(r4.code, (r4.stdout or ''):gsub('\n', ' ')))
