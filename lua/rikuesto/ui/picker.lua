-- Request picker: fzf-lua when available, vim.ui.select otherwise.
local M = {}

local function label(request)
  local parts = { ('%2d'):format(request.index), request.method or 'GET' }
  if request.name and request.name ~= '' then
    parts[#parts + 1] = '@' .. request.name
  end
  parts[#parts + 1] = request.title and ('# ' .. request.title) or request.url or ''
  return table.concat(parts, '  ')
end

--- @param requests table[]
--- @param on_select fun(request: table)|nil
function M.list(requests, on_select)
  on_select = on_select or function() end
  if not requests or #requests == 0 then
    require('rikuesto.util.notify').warn('no requests in this buffer')
    return
  end
  local labels = {}
  for index, request in ipairs(requests) do
    labels[index] = label(request)
  end

  local ok, fzf = pcall(require, 'fzf-lua')
  if ok and fzf and fzf.fzf_exec then
    local launched = pcall(fzf.fzf_exec, labels, {
      prompt = 'rikuesto> ',
      actions = {
        ['default'] = function(selected)
          local choice = selected and selected[1]
          if not choice then
            return
          end
          for index, text in ipairs(labels) do
            if text == choice then
              on_select(requests[index])
              return
            end
          end
        end,
      },
    })
    if launched then
      return
    end
  end

  vim.ui.select(labels, { prompt = 'rikuesto request' }, function(choice)
    if not choice then
      return
    end
    for index, text in ipairs(labels) do
      if text == choice then
        on_select(requests[index])
        return
      end
    end
  end)
end

return M
