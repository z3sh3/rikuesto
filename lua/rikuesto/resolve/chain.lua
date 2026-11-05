-- Named-response references: `{{login.response.body.$.token}}` (DESIGN §6.4, INTERFACES §4).
-- Supported subset: status, body, body.*, body.<JSONPath>, headers.<Name> (case-insensitive).
local M = {}

local function is_list(value)
  if vim.islist then
    return vim.islist(value)
  end
  return value[1] ~= nil
end

local function decode_body(response)
  if type(response.json) == 'table' then
    return response.json
  end
  if type(response.body) ~= 'string' or response.body == '' then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, response.body)
  if not ok or type(decoded) ~= 'table' then
    return nil
  end
  return decoded
end

--- Evaluate a JSONPath subset (`$`, `.key`, `[n]`) against a decoded JSON value.
local function jsonpath(root, path)
  local cursor = root
  local index = 1
  if path:sub(1, 1) == '$' then
    index = 2
  end
  while index <= #path do
    local ch = path:sub(index, index)
    if ch == '.' then
      index = index + 1
    elseif ch == '[' then
      local raw = path:match('^%[(%-?%d+)%]', index)
      if not raw or type(cursor) ~= 'table' then
        return nil
      end
      index = index + #raw + 2
      local position = tonumber(raw)
      -- JSON arrays are 0-based, decoded Lua tables are 1-based
      if is_list(cursor) then
        position = position + 1
      end
      cursor = cursor[position]
    else
      local key = path:match('^([^%[%.]+)', index)
      if not key or type(cursor) ~= 'table' then
        return nil
      end
      index = index + #key
      cursor = cursor[key]
    end
    if cursor == nil then
      return nil
    end
  end
  return cursor
end

local function header_value(response, wanted)
  local headers = response.headers
  if type(headers) ~= 'table' then
    return nil
  end
  local target = wanted:lower()
  if headers[1] ~= nil then
    for _, header in ipairs(headers) do
      if type(header) == 'table' and type(header.name) == 'string' and header.name:lower() == target then
        return header.value
      end
    end
    return nil
  end
  for name, value in pairs(headers) do
    if type(name) == 'string' and name:lower() == target then
      return value
    end
  end
  return nil
end

--- Resolve `expr` against `named_responses` (name -> Response).
--- Also accepts `expr` without the `<name>.` head when `named_responses` is/contains the Response
--- itself (`chain.lookup('response.body.token', { response = resp })`, used by assertions).
function M.lookup(expr, named_responses)
  if type(expr) ~= 'string' or expr == '' or type(named_responses) ~= 'table' then
    return nil
  end

  local head, rest = expr:match('^([^%.]+)%.?(.*)$')
  if not head or rest == '' then
    return nil
  end

  local response = named_responses[head]
  if type(response) ~= 'table' then
    response = nil
  end
  rest = rest:gsub('^response%.?', '', 1)
  if response == nil then
    -- `named_responses` may be the Response itself, or `{ response = <Response> }`
    if head == 'response' then
      response = named_responses
    end
  end
  if rest == '' or type(response) ~= 'table' then
    return nil
  end

  if rest == 'status' then
    return response.status
  end
  if rest == 'body' then
    return response.body
  end

  local path = rest:match('^body%.(.+)$')
  if path then
    if path == '*' then
      return decode_body(response) or response.body
    end
    local json = decode_body(response)
    if json == nil then
      return nil
    end
    return jsonpath(json, path)
  end

  local wanted = rest:match('^headers%.(.+)$')
  if wanted then
    return header_value(response, wanted)
  end
  return nil
end

return M
