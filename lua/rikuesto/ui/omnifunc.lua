-- Completion inside `{{ ... }}`: environment variables, file variables and `$dynamic` helpers.
local M = {}

local DYNAMIC = {
  '$uuid', '$guid', '$timestamp', '$isoTimestamp', '$datetime', '$randomInt',
  '$random.integer', '$random.float', '$random.alphabetic', '$random.alphanumeric',
  '$random.hexadecimal', '$random.email', '$processEnv', '$env', '$projectRoot',
}

local cached_names, cached_key = {}, nil

local function collect_names(bufnr)
  local key = vim.api.nvim_buf_get_changedtick(bufnr)
  if cached_key == key and #cached_names > 0 then
    return cached_names
  end
  local names = {}
  local seen = {}
  local function add(name)
    if name and name ~= '' and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  local ok_env, env_api = pcall(require, 'rikuesto.env.api')
  if ok_env then
    local ok, vars = pcall(env_api.variables)
    if ok and type(vars) == 'table' then
      for name in pairs(vars) do
        add(name)
      end
    end
  end

  local ok_parse, block = pcall(require, 'rikuesto.parse.block')
  if ok_parse then
    local ok, result = pcall(block.parse, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    if ok and result then
      for name in pairs(result.file_variables or {}) do
        add(name)
      end
      for _, request in ipairs(result.requests or {}) do
        for name in pairs(request.variables or {}) do
          add(name)
        end
        if request.name then
          add(request.name .. '.response.body.*')
          add(request.name .. '.response.status')
        end
      end
    end
  end

  table.sort(names)
  cached_names, cached_key = names, key
  return names
end

--- `omnifunc` compatible signature.
function M.complete(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local open = before:match('.*(){{%%?')
    if not open then
      return -3
    end
    return open - 1
  end

  local buf = vim.api.nvim_get_current_buf()
  local items = {}
  local prefix = base or ''

  if prefix:sub(1, 1) == '$' then
    for _, name in ipairs(DYNAMIC) do
      if name:sub(1, #prefix) == prefix then
        items[#items + 1] = { word = name, menu = '[dynamic]', dup = 0, icase = 1 }
      end
    end
    return items
  end

  for _, name in ipairs(collect_names(buf)) do
    if prefix == '' or name:sub(1, #prefix) == prefix then
      items[#items + 1] = { word = name, menu = '[var]', dup = 0, icase = 1 }
    end
  end
  return items
end

function M.invalidate()
  cached_key = nil
end

return M
