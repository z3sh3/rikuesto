-- URL userinfo extraction: `user:pass@` must reach curl as `-u`, never as part of the URL.
local M = {}

--- Split `user:pass` on the FIRST colon (passwords may contain colons).
local function split_userinfo(userinfo)
    local user, pass = userinfo:match('^([^:]*):(.*)$')
    if user then
        return user, pass
    end
    return userinfo, nil
end

--- @param url string
--- @return { user = string, pass = string|nil, clean_url = string }|nil
function M.from_url(url)
    if type(url) ~= 'string' or url == '' then
        return nil
    end
    local scheme, rest = url:match('^(%a[%w+%.%-]*)://(.*)$')
    if not scheme then
        return nil
    end
    -- Userinfo ends at the first `@` and may not span a path/query/fragment delimiter,
    -- so `https://host/api@v1` is not mistaken for credentials.
    local userinfo, tail = rest:match('^([^/%?#@]+)@(.+)$')
    if not userinfo or tail == '' then
        return nil
    end
    local user, pass = split_userinfo(userinfo)
    if user == '' then
        return nil
    end
    return { user = user, pass = pass, clean_url = scheme .. '://' .. tail }
end

return M
