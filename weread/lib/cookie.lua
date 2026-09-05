local Cookie = {}

function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        -- Strip control characters from both key and value to prevent CRLF
        -- header injection (L-1 fix; S-08: the key was previously trusted).
        local safe_key = tostring(key or ""):gsub("[%c]", "")
        local safe_value = tostring(value or ""):gsub("[%c]", "")
        table.insert(parts, safe_key .. "=" .. safe_value)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function Cookie.merge(cookies, updates)
    local merged = {}
    for key, value in pairs(cookies or {}) do
        merged[key] = value
    end
    for key, value in pairs(updates or {}) do
        merged[key] = value
    end
    return merged
end

function Cookie.merge_set_cookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then
        return cookies
    end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            Cookie.merge_set_cookie(cookies, value)
        end
        return cookies
    end
    local allowed = {
        ptcz = true,
        RK = true,
        pgv_pvid = true,
    }
    for name, value in set_cookie:gmatch("([%w_]+)=([^;,\r\n]*)") do
        if name:match("^wr_") or allowed[name] then
            if value == "" then
                cookies[name] = nil
            else
                -- Enforce cookie count and value size limits (L-6 fix)
                local count = 0
                for _ in pairs(cookies) do count = count + 1 end
                if count < 32 and #value <= 4096 then
                    cookies[name] = value
                end
            end
        end
    end
    return cookies
end

function Cookie.has_login_cookie(cookies)
    -- Modern WeRead uses wr_gid instead of wr_skey; fall back to wr_gid as the login credential.
    if cookies and type(cookies.wr_skey) == "string" and #cookies.wr_skey >= 8 then
        return true
    end
    return cookies and type(cookies.wr_gid) == "string" and #cookies.wr_gid >= 5
end

return Cookie
