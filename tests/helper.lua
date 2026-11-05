-- Zero-dependency assertion helper shared by every *_spec.lua file.
-- Usage:  local t = require('tests.helper'); t.module('parse.request'); t.eq(a, b, 'label'); t.finish()
local M = {}

local current_module = 'unknown'
local cases = 0
local failures = {}
local started_at = 0

--- Repo root (grandparent of this file: tests/helper.lua -> repo root).
function M.root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(source, ':p:h:h')
end

function M.module(name)
  current_module = name
  started_at = vim.uv.hrtime()
end

local function record(ok, label, detail)
  cases = cases + 1
  if ok then
    return true
  end
  failures[#failures + 1] = {
    module = current_module,
    label = label,
    detail = detail or '',
  }
  return false
end

local function dump(value)
  if type(value) == 'string' then
    return ('%q'):format(value)
  end
  local ok, out = pcall(vim.inspect, value)
  return ok and out or tostring(value)
end

function M.ok(condition, label)
  return record(not not condition, label)
end

function M.eq(actual, expected, label)
  local ok = actual == expected
  return record(ok, label, ok and '' or ('expected %s, got %s'):format(dump(expected), dump(actual)))
end

function M.ne(actual, expected, label)
  local ok = actual ~= expected
  return record(ok, label, ok and '' or ('expected value different from %s'):format(dump(expected)))
end

function M.same(actual, expected, label)
  local ok = vim.deep_equal(actual, expected)
  return record(ok, label,
    ok and '' or ('expected %s, got %s'):format(dump(expected), dump(actual)))
end

function M.contains(haystack, needle, label)
  local ok = type(haystack) == 'string' and haystack:find(needle, 1, true) ~= nil
  return record(ok, label, ok and '' or ('%s does not contain %s'):format(dump(haystack), dump(needle)))
end

function M.matches(value, pattern, label)
  local ok = type(value) == 'string' and value:match(pattern) ~= nil
  return record(ok, label, ok and '' or ('%s does not match %s'):format(dump(value), dump(pattern)))
end

--- Expect `fn` to raise (or return nil, err).
function M.fails(fn, label)
  local ok, err = pcall(fn)
  return record(not ok, label, ok and 'expected an error, none raised' or '')
end

--- Read a fixture relative to tests/fixtures/.
function M.fixture(name)
  local path = M.root() .. '/tests/fixtures/' .. name
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    error(('missing fixture %s (%s)'):format(name, path))
  end
  return lines, path
end

function M.fixture_text(name)
  return table.concat((M.fixture(name)), '\n')
end

--- Print a per-module summary; returns (cases, failures).
function M.finish()
  local ms = vim.uv.hrtime()
  local elapsed = started_at > 0 and (ms - started_at) / 1e6 or 0
  local failed = 0
  for _, failure in ipairs(failures) do
    if failure.module == current_module then
      failed = failed + 1
    end
  end
  local status = failed == 0 and 'PASS' or 'FAIL'
  print(('%s  %-28s %3d assertions  %6.1fms'):format(status, current_module, cases, elapsed))
  for _, failure in ipairs(failures) do
    if failure.module == current_module then
      print(('      x %s%s'):format(failure.label, failure.detail ~= '' and ('  [' .. failure.detail .. ']') or ''))
    end
  end
  return cases, failed
end

function M.summary()
  local per_module = {}
  for _, failure in ipairs(failures) do
    per_module[failure.module] = (per_module[failure.module] or 0) + 1
  end
  return cases, #failures, per_module
end

return M
