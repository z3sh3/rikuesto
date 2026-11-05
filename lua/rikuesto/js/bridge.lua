-- JSON + base64 plumbing between the Lua driver and the JS harness.
-- Everything here must survive a failure without raising: `runtime.run` turns a
-- `nil, err` return into a user-facing diagnostic.
local M = {}

local B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local B64_INDEX = {}
for i = 1, #B64_ALPHABET do
  B64_INDEX[B64_ALPHABET:sub(i, i)] = i - 1
end

local function fallback_base64_encode(data)
  local out = {}
  local count = #data
  local i = 1
  while i <= count do
    local b1 = data:byte(i)
    local b2 = data:byte(i + 1)
    local b3 = data:byte(i + 2)
    local c1 = math.floor(b1 / 4)
    local c2 = (b1 % 4) * 16 + math.floor((b2 or 0) / 16)
    local c3 = b2 and ((b2 % 16) * 4 + math.floor((b3 or 0) / 64)) or nil
    local c4 = b3 and (b3 % 64) or nil
    out[#out + 1] = B64_ALPHABET:sub(c1 + 1, c1 + 1)
    out[#out + 1] = B64_ALPHABET:sub(c2 + 1, c2 + 1)
    out[#out + 1] = c3 and B64_ALPHABET:sub(c3 + 1, c3 + 1) or '='
    out[#out + 1] = c4 and B64_ALPHABET:sub(c4 + 1, c4 + 1) or '='
    i = i + 3
  end
  return table.concat(out)
end

local function fallback_base64_decode(text)
  local data = text:gsub('%s+', '')
  if #data % 4 ~= 0 then
    return nil
  end
  local out = {}
  for i = 1, #data, 4 do
    local chunk = data:sub(i, i + 3)
    local c1 = B64_INDEX[chunk:sub(1, 1)]
    local c2 = B64_INDEX[chunk:sub(2, 2)]
    local c3 = B64_INDEX[chunk:sub(3, 3)]
    local c4 = B64_INDEX[chunk:sub(4, 4)]
    if not c1 or not c2 then
      return nil
    end
    out[#out + 1] = string.char(c1 * 4 + math.floor(c2 / 16))
    if c3 then
      out[#out + 1] = string.char((c2 % 16) * 16 + math.floor(c3 / 4))
    end
    if c3 and c4 then
      out[#out + 1] = string.char((c3 % 4) * 64 + c4)
    end
  end
  return table.concat(out)
end

--- Serialise a value for the harness stdin. Returns nil, err on failure.
function M.encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return nil, ('json encode failed: %s'):format(tostring(encoded))
  end
  if type(encoded) ~= 'string' then
    return nil, 'json encode failed: encoder returned no string'
  end
  return encoded
end

--- Parse harness stdout. Returns nil, err on failure.
function M.decode(text)
  if type(text) ~= 'string' or text == '' then
    return nil, 'empty json input'
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok then
    return nil, ('json decode failed: %s'):format(tostring(value))
  end
  return value
end

function M.base64_encode(data)
  if type(data) ~= 'string' then
    return nil
  end
  if vim.base64 and vim.base64.encode then
    local ok, encoded = pcall(vim.base64.encode, data)
    if ok and type(encoded) == 'string' then
      return encoded
    end
  end
  return fallback_base64_encode(data)
end

function M.base64_decode(text)
  if type(text) ~= 'string' then
    return nil
  end
  if vim.base64 and vim.base64.decode then
    local ok, decoded = pcall(vim.base64.decode, text)
    if ok and type(decoded) == 'string' then
      return decoded
    end
  end
  return fallback_base64_decode(text)
end

return M
