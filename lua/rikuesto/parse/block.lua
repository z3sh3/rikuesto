-- Splits a `.http` buffer into the file preamble plus `###` blocks and drives
-- `request.parse_chunk` over each of them (docs/DESIGN.md §5.2).
local M = {}

local metadata = require('rikuesto.parse.metadata')
local request = require('rikuesto.parse.request')

local function new_scope()
    return {
        variables = {},
        lazy_variables = {},
        scripts = { pre = {} },
        meta = metadata.empty(),
    }
end

--- Trailing text of a `###` separator line becomes the next block's title.
local function separator_title(line)
    local text = line:gsub('^#+', '')
    text = text:gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then
        return nil
    end
    return text
end

--- Split the buffer into regions: the preamble (rows before the first `###`) and
--- one region per separator. Regions never contain the separator line itself.
local function build_regions(buffer)
    local separators = {}
    for i = 1, #buffer do
        if buffer[i]:match('^###+') then
            separators[#separators + 1] = { row = i - 1, title = separator_title(buffer[i]) }
        end
    end

    local regions = {}
    if #separators == 0 then
        regions[1] = { first_row = 0, end_row = #buffer, title = nil }
        return regions
    end
    if separators[1].row > 0 then
        regions[1] = { first_row = 0, end_row = separators[1].row, title = nil }
    end
    for i, separator in ipairs(separators) do
        local following = separators[i + 1]
        regions[#regions + 1] = {
            first_row = separator.row + 1,
            end_row = following and following.row or #buffer,
            title = separator.title,
        }
    end
    return regions
end

--- Parse a whole `.http` buffer.
--- `lines` is a 1-based array of buffer lines (so `lines[1]` is 0-based row 0).
--- Returns a ParseResult (docs/INTERFACES.md §1.5); never raises.
function M.parse(lines)
    local result = {
        requests = {},
        preamble = {
            variables = {},
            lazy_variables = {},
            scripts = { pre = {} },
            meta = metadata.empty(),
        },
        file_variables = {},
        file_lazy_variables = {},
        diagnostics = {},
    }
    if type(lines) ~= 'table' then
        return result
    end

    local buffer = {}
    for i = 1, #lines do
        buffer[i] = (tostring(lines[i] or ''):gsub('\r$', ''))
    end

    local preamble_scope = new_scope()
    local file_scope = new_scope()
    local has_request = false

    for position, region in ipairs(build_regions(buffer)) do
        local scope = position == 1 and preamble_scope or file_scope
        region.lines = buffer
        -- Declarations before the first request of the file are file-level;
        -- afterwards they belong to the request block (docs/DESIGN.md §6.1).
        region.head_scope = has_request and 'block' or 'file'
        local req, diagnostics = request.parse_chunk(region, scope)
        for _, diagnostic in ipairs(diagnostics or {}) do
            result.diagnostics[#result.diagnostics + 1] = diagnostic
        end
        if req then
            req.index = #result.requests + 1
            result.requests[#result.requests + 1] = req
            has_request = true
        end
    end

    result.preamble.variables = preamble_scope.variables
    result.preamble.lazy_variables = preamble_scope.lazy_variables
    result.preamble.scripts = preamble_scope.scripts
    result.preamble.meta = preamble_scope.meta

    for name, value in pairs(preamble_scope.variables) do
        result.file_variables[name] = value
    end
    for name, value in pairs(file_scope.variables) do
        result.file_variables[name] = value
    end
    for name in pairs(preamble_scope.lazy_variables) do
        result.file_lazy_variables[name] = true
    end
    for name in pairs(file_scope.lazy_variables) do
        result.file_lazy_variables[name] = true
    end
    for _, script in ipairs(file_scope.scripts.pre) do
        result.preamble.scripts.pre[#result.preamble.scripts.pre + 1] = script
    end
    metadata.merge(result.preamble.meta, file_scope.meta)

    return result
end

--- Request whose `range` contains `row` (0-based). Rows in the preamble, on a
--- `###` line, or in the blank gap after a block return nil.
function M.request_at(result, row)
    if type(result) ~= 'table' or type(row) ~= 'number' then
        return nil
    end
    for _, req in ipairs(result.requests or {}) do
        local range = req.range
        if range and row >= range.start_row and row < range.end_row then
            return req
        end
    end
    return nil
end

return M
