-- Virtual-text summaries at the end of each request block's first line.
local M = {}

local config = require('rikuesto.config')

local namespace = vim.api.nvim_create_namespace('rikuesto-result')

local function summary_text(summary)
  if not summary then
    return nil
  end
  if summary.error then
    return ('%s: %s'):format(summary.error.kind or 'error', summary.error.message or ''), 'RikuestoError'
  end
  local parts = {}
  parts[#parts + 1] = tostring(summary.status or '?')
  if summary.duration_ms then
    parts[#parts + 1] = ('%dms'):format(math.floor(summary.duration_ms + 0.5))
  end
  if summary.size then
    parts[#parts + 1] = ('%dB'):format(summary.size)
  end
  local group = (summary.ok and 'RikuestoOk' or 'RikuestoFail')
  return table.concat(parts, ' · '), group
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, 'RikuestoOk', { link = 'DiagnosticOk', default = true })
  vim.api.nvim_set_hl(0, 'RikuestoFail', { link = 'DiagnosticError', default = true })
  vim.api.nvim_set_hl(0, 'RikuestoError', { link = 'DiagnosticError', default = true })
end

--- Place (or replace) the result badge for one request.
function M.set_result(bufnr, request, response)
  if not config.get().ui.extmark.enabled then
    return
  end
  bufnr = bufnr or 0
  if not vim.api.nvim_buf_is_valid(bufnr) or not request then
    return
  end
  ensure_highlights()
  local state = require('rikuesto.state')
  local summary = state.result_for(bufnr, request.index)
    or {
      status = response and response.status,
      duration_ms = response and response.duration_ms,
      size = response and response.size,
      ok = response and response.ok and (response.status or 0) < 400,
      error = response and response.error,
    }
  local text, group = summary_text(summary)
  if not text then
    return
  end
  local row = (request.range and request.range.start_row) or request.url_line or 0
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, row, row + 1)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, row, 0, {
    virt_text = { { '  ' .. text, group } },
    virt_text_pos = 'eol',
    hl_mode = 'combine',
  })
end

function M.clear(bufnr)
  bufnr = bufnr or 0
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  end
end

function M.namespace()
  return namespace
end

return M
