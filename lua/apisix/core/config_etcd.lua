-- Copyright (C) Yuansheng Wang

local fetch_local_conf = require("apisix.core.config_local").local_conf
local log          = require("apisix.core.log")
local json         = require("apisix.core.json")
local etcd         = require("resty.etcd")
local new_tab      = require("table.new")
local clone_tab    = require("table.clone")
local check_schema = require("apisix.core.schema").check
local exiting      = ngx.worker.exiting
local insert_tab   = table.insert
local type         = type
local ipairs       = ipairs
local setmetatable = setmetatable
local ngx_sleep    = ngx.sleep
local ngx_timer_at = ngx.timer.at
local ngx_time     = ngx.time
local sub_str      = string.sub
local tostring     = tostring
local tonumber     = tonumber
local pcall        = pcall


local _M = {
    version = 0.1,
    local_conf = fetch_local_conf,
}
local mt = {
    __index = _M,
    __tostring = function(self)
        return " etcd key: " .. self.key
    end
}

local function readdir(etcd_cli, key)
    if not etcd_cli then
        return nil, nil, "not inited"
    end

    local data, err = etcd_cli:readdir(key, true)
    if not data then
        -- log.error("failed to get key from etcd: ", err)
        return nil, nil, err
    end

    local body = data.body

    if type(body) ~= "table" then
        return nil, nil, "failed to read etcd dir"
    end

    if body.message then
        return nil, nil, body.message
    end

    return body.node, data.headers
end

local function waitdir(etcd_cli, key, modified_index)
    if not etcd_cli then
        return nil, nil, "not inited"
    end

    local data, err = etcd_cli:waitdir(key, modified_index)
    if not data then
        -- log.error("failed to get key from etcd: ", err)
        return nil, nil, err
    end

    local body = data.body or {}

    if body.message then
        return nil, nil, body.message
    end

    return body.node, data.headers
end


local function short_key(self, str)
    return sub_str(str, #self.key + 2)
end


function _M.upgrade_version(self, new_ver)
    new_ver = tonumber(new_ver)
    if not new_ver then
        return
    end

    local pre_index = self.prev_index
    if not pre_index then
        self.prev_index = new_ver
        return
    end

    if new_ver <= pre_index then
        return
    end

    self.prev_index = new_ver
    return
end


local function sync_data(self)
    if not self.key then
        return nil, "missing 'key' arguments"
    end

    if self.values == nil then
        local dir_res, headers, err = readdir(self.etcd_cli, self.key)
        log.debug("readdir key: ", self.key, " res: ",
                  json.delay_encode(dir_res))
        if not dir_res then
            return false, err
        end

        if not dir_res.dir then
            return false, self.key .. " is not a dir"
        end

        if not dir_res.nodes then
            dir_res.nodes = {}
        end

        self.values = new_tab(#dir_res.nodes, 0)
        self.values_hash = new_tab(0, #dir_res.nodes)

        local changed = false
        for _, item in ipairs(dir_res.nodes) do
            local key = short_key(self, item.key)
            local data_valid = true
            if type(item.value) ~= "table" then
                data_valid = false
                log.error("invalid item data of [", self.key .. "/" .. key,
                          "], val: ", tostring(item.value),
                          ", it shoud be a object")
            end

            if data_valid and self.item_schema then
                data_valid, err = check_schema(self.item_schema, item.value)
                if not data_valid then
                    log.error("failed to check item data of [", self.key,
                              "] err:", err, " ,val: ", json.encode(item.value))
                end
            end

            if data_valid then
                changed = true
                insert_tab(self.values, item)
                self.values_hash[key] = #self.values
                item.value.id = key
            end

            self:upgrade_version(item.modifiedIndex)
        end

        if headers then
            self:upgrade_version(headers["X-Etcd-Index"])
        end

        if changed then
            self.conf_version = self.conf_version + 1
        end
        return true
    end

    local res, headers, err = waitdir(self.etcd_cli, self.key,
                                      self.prev_index + 1)
    log.debug("waitdir key: ", self.key, " prev_index: ", self.prev_index + 1,
              " res: ", json.delay_encode(res, true),
              " headers: ", json.delay_encode(headers, true))
    if not res then
        return false, err
    end

    local key = short_key(self, res.key)
    if res.value and type(res.value) ~= "table" then
        self:upgrade_version(res.modifiedIndex)
        return false, "invalid item data of [" .. self.key .. "/" .. key
                      .. "], val: " .. tostring(res.value)
                      .. ", it shoud be a object"
    end

    if res.value and self.item_schema then
        local ok, err = check_schema(self.item_schema, res.value)
        if not ok then
            self:upgrade_version(res.modifiedIndex)

            return false, "failed to check item data of ["
                          .. self.key .. "] err:" .. err
        end
    end

    self:upgrade_version(res.modifiedIndex)

    if res.dir then
        return false, "todo: support for parsing `dir` response "
                      .. "structures. " .. json.encode(res)
    end

    local pre_index = self.values_hash[key]
    if pre_index then
        if res.value then
            res.value.id = key
            self.values[pre_index] = res

        else
            self.sync_times = self.sync_times + 1
            self.values[pre_index] = false
        end

    elseif res.value then
        insert_tab(self.values, res)
        self.values_hash[key] = #self.values
        res.value.id = key
    end

    -- avoid space waste
    -- todo: need to cover this path, it is important.
    if self.sync_times > 100 then
        local count = 0
        for i = 1, #self.values do
            local val = self.values[i]
            self.values[i] = nil
            if val then
                count = count + 1
                self.values[count] = val
            end
        end

        for i = 1, count do
            key = short_key(self, self.values[i].key)
            self.values_hash[key] = i
        end
    end

    self.conf_version = self.conf_version + 1
    return self.values
end


function _M.get(self, key)
    if not self.values_hash then
        return
    end

    local arr_idx = self.values_hash[tostring(key)]
    if not arr_idx then
        return nil
    end

    return self.values[arr_idx]
end


local function _automatic_fetch(premature, self)
    if premature then
        return
    end

    local i = 0
    while not exiting() and self.running and i <= 32 do
        i = i + 1
        local ok, ok2, err = pcall(sync_data, self)
        if not ok then
            err = ok2
            log.error("failed to fetch data from etcd: ", err, ", ",
                      tostring(self))
            ngx_sleep(3)
            break

        elseif not ok2 and err then
            if err ~= "timeout" and err ~= "Key not found"
               and self.last_err ~= err then
                log.error("failed to fetch data from etcd: ", err, ", ",
                          tostring(self))
            end

            if err ~= self.last_err then
                self.last_err = err
                self.last_err_time = ngx_time()
            else
                if ngx_time() - self.last_err_time >= 30 then
                    self.last_err = nil
                end
            end
            ngx_sleep(0.5)

        elseif not ok2 then
            ngx_sleep(0.05)
        end
    end

    if not exiting() and self.running then
        ngx_timer_at(0, _automatic_fetch, self)
    end
end


function _M.new(key, opts)
    local local_conf, err = fetch_local_conf()
    if not local_conf then
        return nil, err
    end

    local etcd_conf = clone_tab(local_conf.etcd)
    local prefix = etcd_conf.prefix
    etcd_conf.prefix = nil

    local etcd_cli
    etcd_cli, err = etcd.new(etcd_conf)
    if not etcd_cli then
        return nil, err
    end

    local automatic = opts and opts.automatic
    local item_schema = opts and opts.item_schema

    local obj = setmetatable({
        etcd_cli = etcd_cli,
        key = key and prefix .. key,
        automatic = automatic,
        item_schema = item_schema,
        sync_times = 0,
        running = true,
        conf_version = 0,
        values = nil,
        routes_hash = nil,
        prev_index = nil,
        last_err = nil,
        last_err_time = nil,
    }, mt)

    if automatic then
        if not key then
            return nil, "missing `key` argument"
        end

        ngx_timer_at(0, _automatic_fetch, obj)
    end

    return obj
end


function _M.close(self)
    self.running = false
end


local function read_etcd_version(etcd_cli)
    if not etcd_cli then
        return nil, "not inited"
    end

    local data, err = etcd_cli:version()
    if not data then
        return nil, err
    end

    local body = data.body
    if type(body) ~= "table" then
        return nil, "failed to read response body when try to fetch etcd "
                    .. "version"
    end

    return body
end

function _M.server_version(self)
    if not self.running then
        return nil, "stoped"
    end

    return read_etcd_version(self.etcd_cli)
end


return _M
