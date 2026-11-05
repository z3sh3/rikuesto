-- Shared mutable state: named responses (for {{login.response...}}), last run, per-buffer results.
local M = {}

--- Named responses keyed by `# @name` (request name -> Response).
M.named = {}

--- Values set through `client.global.set()`.
M.globals = {}

--- Last executed request/response pair.
M.last = nil

--- Active runner job (for cancellation).
M.job = nil

--- Per-buffer summaries: bufnr -> request.index -> summary.
M.results = {}

function M.remember_request(name, response)
  if name and name ~= '' then
    M.named[name] = response
  end
end

function M.named_response(name)
  return M.named[name]
end

function M.set_global(key, value)
  M.globals[key] = value
end

function M.get_global(key)
  return M.globals[key]
end

function M.clear_globals()
  M.globals = {}
end

function M.record_result(bufnr, request, response)
  M.results[bufnr] = M.results[bufnr] or {}
  M.results[bufnr][request.index] = {
    status = response and response.status,
    duration_ms = response and response.duration_ms,
    size = response and response.size,
    ok = response and response.ok and (response.status or 0) < 400,
    error = response and response.error,
  }
  M.last = { bufnr = bufnr, request = request, response = response }
end

function M.result_for(bufnr, index)
  local per_buffer = M.results[bufnr]
  return per_buffer and per_buffer[index] or nil
end

function M.reset()
  M.named = {}
  M.globals = {}
  M.last = nil
  M.job = nil
  M.results = {}
end

return M
