local _M = {}

_M.DEFAULT_COOLDOWN_ON = {429}
_M.DEFAULT_DISABLE_ON = {402, 403}
_M.DEFAULT_COOLDOWN_S = 3600

function _M.status_in(list, status)
    if type(list) ~= "table" then
        return false
    end
    local n = tonumber(status)
    if not n then
        return false
    end
    for _, v in ipairs(list) do
        if tonumber(v) == n then
            return true
        end
    end
    return false
end

function _M.cooldown_on(pool)
    if type(pool) == "table" and type(pool.cooldown_on) == "table" and #pool.cooldown_on > 0 then
        return pool.cooldown_on
    end
    return _M.DEFAULT_COOLDOWN_ON
end

function _M.disable_on(pool)
    if type(pool) == "table" and type(pool.disable_on) == "table" and #pool.disable_on > 0 then
        return pool.disable_on
    end
    return _M.DEFAULT_DISABLE_ON
end

function _M.cooldown_s(pool)
    local v = type(pool) == "table" and tonumber(pool.cooldown_s) or nil
    if v and v > 0 then
        return v
    end
    return _M.DEFAULT_COOLDOWN_S
end

function _M.select_sticky(pool, is_unavailable)
    if type(pool) ~= "table" or type(pool.keys) ~= "table" then
        return nil, "pool has no keys"
    end
    for i, entry in ipairs(pool.keys) do
        if type(entry) == "table"
            and entry.active ~= false
            and type(entry.key) == "string"
            and entry.key ~= ""
            and not (is_unavailable and is_unavailable(entry.id)) then
            return entry, i
        end
    end
    return nil, "no available keys"
end

function _M.mark_disabled(pool, key_id)
    if type(pool) ~= "table" or type(pool.keys) ~= "table" then
        return nil, "pool has no keys"
    end
    for _, entry in ipairs(pool.keys) do
        if type(entry) == "table" and entry.id == key_id then
            entry.active = false
            return pool
        end
    end
    return nil, "key not found in pool: " .. tostring(key_id)
end

return _M
