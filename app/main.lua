--- ccserver reference app entry.
---
--- Run a node by id:
---   moon_rs app/main.lua 1
---   CCS_NODE_ID=2 moon_rs app/main.lua
---
--- The topology (`app/config/topology.lua`) decides which services run here.

local moon = require("moon")
local node = require("ccserver.node")
local topology = require("ccserver.topology")

local args = moon.args()
local node_id = tonumber(args[1]) or tonumber(os.getenv("CCS_NODE_ID")) or 1

moon.async(function()
    local cfg = topology.load("config/topology.lua")
    node.start(cfg, node_id)
    moon.info(string.format("ccserver node %d ready", node_id))
end)

moon.shutdown(function()
    node.stop()
end)
