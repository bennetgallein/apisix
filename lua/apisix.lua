-- Copyright (C) Yuansheng Wang

local require = require
local core = require("apisix.core")
local router = require("apisix.route").get
local plugin_module = require("apisix.plugin")
local new_tab = require("table.new")
local load_balancer = require("apisix.balancer") .run
local ngx = ngx


local _M = {version = 0.1}


function _M.init()
    require("resty.core")
    require("ngx.re").opt("jit_stack_size", 200 * 1024)
    require("jit.opt").start("minstitch=2", "maxtrace=4000",
                             "maxrecord=8000", "sizemcode=64",
                             "maxmcode=4000", "maxirconst=1000")
end


function _M.init_worker()
    require("apisix.route").init_worker()
    require("apisix.balancer").init_worker()
    require("apisix.plugin").init_worker()
end


local function run_plugin(phase, filter_plugins, api_ctx)
    api_ctx = api_ctx or ngx.ctx.api_ctx
    if not api_ctx then
        return
    end

    filter_plugins = filter_plugins or api_ctx.filter_plugins
    if not filter_plugins then
        return
    end

    for i = 1, #filter_plugins, 2 do
        local plugin = filter_plugins[i]
        local phase_fun = plugin[phase]
        if  phase_fun then
            local code, body = phase_fun(filter_plugins[i + 1], api_ctx)
            if phase ~= "log" and type(code) == "number" or body then
                core.response.exit(code, body)
            end
        end
    end
end


function _M.rewrite_phase()
    local ngx_ctx = ngx.ctx
    local api_ctx = ngx_ctx.api_ctx

    if api_ctx == nil then
        -- todo: reuse this table
        api_ctx = new_tab(0, 32)
    end

    local method = core.request.var(api_ctx, "method")
    local uri = core.request.var(api_ctx, "uri")
    -- local host = core.request.var(api_ctx, "host") -- todo: support host

    local api_router = plugin_module.api_router()
    if api_router and api_router.dispatch then
        -- dispatch
        local ok = api_router:dispatch(method, uri, api_ctx)
        if ok then
            core.log.warn("finish api route")
            return
        end
    end

    ngx_ctx.api_ctx = api_ctx

    local ok = router():dispatch(method, uri, api_ctx)
    if not ok then
        core.log.warn("not find any matched route")
        return core.response.exit(404)
    end

    if api_ctx.matched_route.service_id then
        error("todo: suppport to use service fetch user config")
    else
        api_ctx.conf_type = "route"
        api_ctx.conf_version = api_ctx.matched_route.modifiedIndex
        api_ctx.conf_id = api_ctx.matched_route.value.id
    end

    local filter_plugins = plugin_module.filter_plugin(
        api_ctx.matched_route)

    api_ctx.filter_plugins = filter_plugins

    run_plugin("rewrite", filter_plugins, api_ctx)
end

function _M.access_phase()
    run_plugin("access")
end

function _M.header_filter_phase()
    run_plugin("header_filter")
end

function _M.log_phase()
    run_plugin("log")
end

function _M.balancer_phase()
    local api_ctx = ngx.ctx.api_ctx
    if not api_ctx or not api_ctx.filter_plugins then
        return
    end

    -- TODO: fetch the upstream by upstream_id
    load_balancer(api_ctx.matched_route, api_ctx)
end

return _M
