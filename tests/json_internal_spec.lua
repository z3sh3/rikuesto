-- json_internal: order-preserving, whitespace-only JSON printer (DESIGN appendix C).
local t = require('tests.helper')
local json_internal = require('rikuesto.format.json_internal')

t.module('json_internal')

-- Nested objects/arrays ------------------------------------------------------
t.eq(
    json_internal.pretty('{"a":{"b":[1,{"c":2}]}}', 2),
    '{\n  "a": {\n    "b": [\n      1,\n      {\n        "c": 2\n      }\n    ]\n  }\n}',
    'nested objects and arrays are indented by depth')

t.eq(
    json_internal.pretty('[{"a":1},{"b":2}]', 2),
    '[\n  {\n    "a": 1\n  },\n  {\n    "b": 2\n  }\n]',
    'array of objects')

t.eq(json_internal.pretty('{}', 2), '{}', 'empty object stays on one line')
t.eq(json_internal.pretty('[ ]', 2), '[]', 'empty array stays on one line')
t.eq(json_internal.pretty('{"a":{},"b":[]}', 2), '{\n  "a": {},\n  "b": []\n}', 'empty containers nested')

-- Key order and literals -----------------------------------------------------
t.eq(json_internal.pretty('{"z":1,"a":2}', 2), '{\n  "z": 1,\n  "a": 2\n}', 'key order preserved')
t.eq(json_internal.pretty('{"z":1,"a":2,"m":3}', 2), '{\n  "z": 1,\n  "a": 2,\n  "m": 3\n}',
    'key order preserved for three keys')

t.eq(json_internal.pretty('{"n":1234567890123456789}', 2), '{\n  "n": 1234567890123456789\n}',
    'big integer literal preserved')
t.eq(json_internal.pretty('{"n":1.0}', 2), '{\n  "n": 1.0\n}', '1.0 is not collapsed to 1')
t.eq(json_internal.pretty('{"n":-0,"e":1e+30}', 2), '{\n  "n": -0,\n  "e": 1e+30\n}',
    'negative zero and exponent literals preserved')

-- Strings are copied byte for byte ------------------------------------------
t.eq(json_internal.pretty('{"a":"\\u00e9\\n"}', 2), '{\n  "a": "\\u00e9\\n"\n}', '\\u escapes untouched')
t.eq(json_internal.pretty('{"a":"x\\"y:z"}', 2), '{\n  "a": "x\\"y:z"\n}',
    'escaped quote and colon inside a string stay put')
t.eq(json_internal.pretty('{"a":"{[,:]}","b":1}', 2), '{\n  "a": "{[,:]}",\n  "b": 1\n}',
    'structural characters inside strings are not treated as structure')
t.eq(json_internal.pretty('{"a":"中文 ✓"}', 2), '{\n  "a": "中文 ✓"\n}', 'UTF-8 content preserved')

-- Broken / non-JSON input is returned unchanged ------------------------------
t.eq(json_internal.pretty('{"a":1', 2), '{"a":1', 'unbalanced object returned unchanged')
t.eq(json_internal.pretty('[1,2}', 2), '[1,2}', 'mismatched closer returned unchanged')
t.eq(json_internal.pretty('{"a":1}x', 2), '{"a":1}x', 'trailing garbage returned unchanged')
t.eq(json_internal.pretty('{"a":"unterminated}', 2), '{"a":"unterminated}', 'unterminated string unchanged')
t.eq(json_internal.pretty('a=1&b=2', 2), 'a=1&b=2', 'urlencoded payload untouched')
t.eq(json_internal.pretty('42', 2), '42', 'bare scalar untouched')
t.eq(json_internal.pretty('', 2), '', 'empty input unchanged')

-- Indent option --------------------------------------------------------------
t.eq(json_internal.pretty('{"a":1}', 4), '{\n    "a": 1\n}', 'custom indent width')
t.eq(json_internal.pretty('{"a":1}', '\t'), '{\n\t"a": 1\n}', 'tab indent')
t.eq(json_internal.pretty('{"a":1}'), '{\n  "a": 1\n}', 'default indent is two spaces')

-- Idempotency ----------------------------------------------------------------
local messy = '{"z":1, "a":[1,2,{"k":"v"}], "s":"a, b: c"}'
local once = json_internal.pretty(messy, 2)
t.eq(json_internal.pretty(once, 2), once, 'pretty is idempotent')
t.eq(once, json_internal.pretty(json_internal.pretty(json_internal.pretty(messy, 2), 2), 2),
    'repeated pretty calls are stable')

t.finish()
