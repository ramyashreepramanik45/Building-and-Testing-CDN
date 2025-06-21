-- local resty_chash = require "resty.chash"
-- local http = require "resty.http"
-- local health_dict = ngx.shared.server_health
-- local loadbalancer = {}


-- local function check_health(premature,servers)
--   if premature then return end

--   for server, _ in pairs(servers) do
--     local httpc = http.new()
--     httpc:set_timeout(1000)

--     local ok, err = httpc:request_uri("http://" .. server .. ":8080/healthz", {
--       method = "GET"
--     })

--     if ok and ok.status == 200 then
--       health_dict:set(server, true)
--     else
--       health_dict:set(server, false)
--       ngx.log(ngx.ERR, "[HealthCheck] Server down: ", server, " - ", err)
--     end
--   end
-- end


-- -- Return only healthy servers
-- local function get_healthy_servers()
--   local all_servers = package.loaded.my_servers or {}
--   local healthy_servers = {}

--   for server, weight in pairs(all_servers) do
--     local is_healthy = health_dict:get(server)
--     if is_healthy then
--       healthy_servers[server] = weight
--     end
--   end

--   return healthy_servers
-- end


-- loadbalancer.setup_server_list = function()
--   local server_list = {
--     ["edge"] = 1,
--     ["edge1"] = 1,
--     ["edge2"] = 1,
--   }

--   package.loaded.my_servers = server_list

--   -- Start periodic health check
--   local ok, err = ngx.timer.every(5, check_health, server_list)
--   if not ok then
--     ngx.log(ngx.ERR, "[LB] Failed to start health check timer: ", err)
--   end
-- end


-- --   local chash_up = resty_chash:new(server_list)

-- --   package.loaded.my_chash_up = chash_up
-- --   package.loaded.my_servers = server_list
-- -- end

-- loadbalancer.set_proper_server = function()
--   local b = require "ngx.balancer"
--   local ip_servers = package.loaded.my_ip_servers
--   local healthy_servers = get_healthy_servers()

--   if not next(healthy_servers) then
--     ngx.log(ngx.ERR, "[LB] No healthy upstreams available")
--     return ngx.exit(502)
--   end

--   -- Create hash ring from only healthy servers
--   local chash_up = resty_chash:new(healthy_servers)
--   local id = chash_up:find(ngx.var.uri)

--   local ip = ip_servers and ip_servers[id]
--   if not ip then
--     ngx.log(ngx.ERR, "[LB] No resolved IP for healthy server: ", id)
--     return ngx.exit(502)
--   end

--   local ok, err = b.set_current_peer(ip .. ":8080")
--   if not ok then
--     ngx.log(ngx.ERR, "[LB] Failed to set peer: ", err)
--     return ngx.exit(502)
--   end
-- end

-- loadbalancer.resolve_name_for_upstream = function()
--   local resolver = require "resty.dns.resolver"
--   local r, err = resolver:new{
--     nameservers = {"127.0.0.11", {"127.0.0.11", 53} },
--     retrans = 5,
--     timeout = 1000,
--     no_random = true,
--   }
--   -- quick hack, we could use ips already
--   -- or resolve names on background
--   if package.loaded.my_ip_servers ~= nil then
--     return
--   end

--   local servers = package.loaded.my_servers
--   local ip_servers = {}

--   for host, _ in pairs(servers) do
--     local answers, err = r:query(host, nil, {})
--     if not answers or not answers[1] or not answers[1].address then
--       ngx.log(ngx.ERR, "[DNS] Failed to resolve: ", host, " - ", err)
--     else
--       ip_servers[host] = answers[1].address
--     end
--   end

--   package.loaded.my_ip_servers  = ip_servers
-- end

-- return loadbalancer

local http = require "resty.http"
local health_dict = ngx.shared.server_health
local load_dict = ngx.shared.server_load
local loadbalancer = {}

-- Periodic health checks
local function check_health(premature, servers)
  if premature then return end

  for server, _ in pairs(servers) do
    local httpc = http.new()
    httpc:set_timeout(1000)

    local ok, err = httpc:request_uri("http://" .. server .. ":8080/healthz", {
      method = "GET"
    })

    if ok and ok.status == 200 then
      health_dict:set(server, true)
    else
      health_dict:set(server, false)
      ngx.log(ngx.ERR, "[HealthCheck] Server down: ", server, " - ", err)
    end
  end
end

-- Healthy servers only
local function get_healthy_servers()
  local all_servers = package.loaded.my_servers or {}
  local healthy_servers = {}

  for server, weight in pairs(all_servers) do
    if health_dict:get(server) then
      healthy_servers[server] = weight
    end
  end

  return healthy_servers
end

-- Get current request load for server
local function get_server_load(server)
  return load_dict:get(server) or 0
end

-- Update load: increment on request start
local function increment_load(server)
  load_dict:incr(server, 1, 0)
end

-- Setup initial server list
loadbalancer.setup_server_list = function()
  local server_list = {
    ["edge"] = 1,
    ["edge1"] = 1,
    ["edge2"] = 1,
  }
  
  package.loaded.my_servers = server_list

  if ngx.worker.id() == 0 then
    local ok, err = ngx.timer.at(0, function(premature)
      if premature then return end

      local ok2, err2 = ngx.timer.every(5, check_health, server_list)
      if not ok2 then
        ngx.log(ngx.ERR, "[LB] Failed to create health check timer: ", err2)
      end
    end)

    if not ok then
      ngx.log(ngx.ERR, "[LB] Failed to initialize delayed health check timer: ", err)
    end
  end
end


-- Resolve hostnames to IPs
loadbalancer.resolve_name_for_upstream = function()
  local resolver = require "resty.dns.resolver"
  local r, err = resolver:new{
    nameservers = {"127.0.0.11", {"127.0.0.11", 53} },
    retrans = 5,
    timeout = 1000,
    no_random = true,
  }

  if package.loaded.my_ip_servers ~= nil then return end

  local servers = package.loaded.my_servers
  local ip_servers = {}

  for host, _ in pairs(servers) do
    local answers, err = r:query(host, nil, {})
    if not answers or not answers[1] or not answers[1].address then
      ngx.log(ngx.ERR, "[DNS] Failed to resolve: ", host, " - ", err)
    else
      ip_servers[host] = answers[1].address
    end
  end

  package.loaded.my_ip_servers = ip_servers
end

-- P2C with average-bound and fallback
loadbalancer.set_proper_server = function()
  local b = require "ngx.balancer"
  local healthy_servers = get_healthy_servers()
  local ip_servers = package.loaded.my_ip_servers or {}

  if not next(healthy_servers) then
    ngx.log(ngx.ERR, "[LB] No healthy upstreams available")
    return ngx.exit(502)
  end

  -- Compute average load
  local total = 0
  local count = 0
  for srv, _ in pairs(healthy_servers) do
    total = total + get_server_load(srv)
    count = count + 1
  end
  local avg_load = count > 0 and total / count or 0
  local bound = 1.25

  -- Pick 2 random healthy servers
  local keys = {}
  for srv in pairs(healthy_servers) do
    table.insert(keys, srv)
  end

  local function random_two()
    local i = math.random(#keys)
    local j
    repeat j = math.random(#keys) until j ~= i
    return keys[i], keys[j]
  end

  local s1, s2 = random_two()
  local l1, l2 = get_server_load(s1), get_server_load(s2)

  local selected
  if l1 <= avg_load * bound and l2 <= avg_load * bound then
    selected = (l1 <= l2) and s1 or s2
  elseif l1 <= avg_load * bound then
    selected = s1
  elseif l2 <= avg_load * bound then
    selected = s2
  else
    -- fallback: pick global least-loaded
    local min_load = math.huge
    for srv in pairs(healthy_servers) do
      local load = get_server_load(srv)
      if load < min_load then
        min_load = load
        selected = srv
      end
    end
  end

  local ip = ip_servers[selected]
  if not ip then
    ngx.log(ngx.ERR, "[LB] No resolved IP for selected server: ", selected)
    return ngx.exit(502)
  end

  local ok, err = b.set_current_peer(ip .. ":8080")
  if not ok then
    ngx.log(ngx.ERR, "[LB] Failed to set peer: ", err)
    return ngx.exit(502)
  end

  -- Optional: increment load for accounting
  increment_load(selected)
end

return loadbalancer
