--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local limit_local_new = require("resty.limit.count").new
local core = require("apisix.core")
local plugin_name = "limit-count"
local limit_redis_new
do
    local redis_src = "apisix.plugins.limit-count.limit-count-redis"
    limit_redis_new = require(redis_src).new
end


local schema = {
    type = "object",
    properties = {
        count = {type = "integer", minimum = 0},
        time_window = {type = "integer",  minimum = 0},
        key = {
            type = "string",
            enum = {"remote_addr", "server_addr", "http_x_real_ip",
                    "http_x_forwarded_for"},
        },
        rejected_code = {type = "integer", minimum = 200, maximum = 600,
                         default = 503},
        policy = {
            type = "string",
            enum = {"local", "redis"},
        },
        redis_host = {
            type = "string", minLength = 2
        },
        redis_port = {
            type = "integer", minimum = 1
        },
        redis_password = {
            type = "string", minLength = 0
        },
        redis_timeout = {
            type = "integer", minimum = 1
        },
    },
    additionalProperties = false,
    required = {"count", "time_window", "key"},
}


local _M = {
    version = 0.3,
    priority = 1002,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if not conf.policy then
        conf.policy = "local"
    end

    if conf.policy == "redis" then
        if not conf.redis_host then
            return false, "missing valid redis option host"
        end

        conf.redis_port = conf.redis_port or 6379
        conf.redis_timeout = conf.redis_timeout or 1000
    end

    return true
end


local function create_limit_obj(conf)
    core.log.info("create new limit-count plugin instance")

    if not conf.policy or conf.policy == "local" then
        return limit_local_new("plugin-" .. plugin_name, conf.count,
                               conf.time_window)
    end

    if conf.policy == "redis" then
        return limit_redis_new("plugin-" .. plugin_name,
                               conf.count, conf.time_window, conf)
    end

    return nil
end


function _M.access(conf, ctx)
    core.log.info("ver: ", ctx.conf_version)
    local lim, err = core.lrucache.plugin_ctx(plugin_name, ctx,
                                              create_limit_obj, conf)
    if not lim then
        core.log.error("failed to fetch limit.count object: ", err)
        return 500
    end

    local key = (ctx.var[conf.key] or "") .. ctx.conf_type .. ctx.conf_version
    core.log.info("limit key: ", key)

    local delay, remaining = lim:incoming(key, true)
    if not delay then
        local err = remaining
        if err == "rejected" then
            return conf.rejected_code
        end

        core.log.error("failed to limit req: ", err)
        return 500, {error_msg = "failed to limit count: " .. err}
    end

    core.response.set_header("X-RateLimit-Limit", conf.count,
                             "X-RateLimit-Remaining", remaining)
end


return _M
