-- Restore only settings known to this firmware. A backup is data, never a script.
local tools = require "8311.tools"
local base64 = require "base64"
local M = { limit = 65536 }

local function fields(categories)
	local result = {}
	for _, category in ipairs(categories) do
		for _, item in ipairs(category.items) do
			if not item.base then
				result[item.id] = { item = item, protected = category.id == "pon" }
			end
		end
	end
	return result
end

local function validate(item, value)
	-- An empty stored value removes the override and restores the image default.
	if value == "" then return true end
	if item.id == "persist_root" and value ~= "0" then
		return false, "Restoring a persistent RootFS setting is not supported."
	end
	if item.base64 then
		local decoded = base64.dec(value)
		if not decoded or base64.enc(decoded) ~= value then return false, "Invalid Base64 setting." end
		value = decoded
	elseif item.type == "checkbox_onoff" then
		if value ~= "on" and value ~= "off" then return false, "Invalid checkbox value." end
		value = value == "on" and "1" or "0"
	end
	return tools.validate_config_value(item, value)
end

function M.plan(content, categories, current, preserve_pon, reset)
	if current.persist_root == "1" then
		return nil, "Disable Persist RootFS and reboot before restoring settings."
	end
	local definitions, incoming, seen = fields(categories), {}, {}
	if reset then
		for id in pairs(definitions) do incoming[id] = "" end
	else
		if type(content) ~= "string" or #content == 0 or #content > M.limit then
			return nil, "Choose a non-empty 8311 settings file no larger than 64 KiB."
		end
		content = content:gsub("\r\n", "\n")
		if content:find("[%z\1-\9\11-\31\127]") then
			return nil, "The settings file must contain plain text key=value lines."
		end
		for line in (content .. "\n"):gmatch("([^\n]*)\n") do
			if line ~= "" and not line:match("^#") then
				local id, value = line:match("^8311_([%w_]+)=(.*)$")
				if not id or not definitions[id] then return nil, "The file contains an unsupported setting." end
				if seen[id] then return nil, "The file contains a duplicate setting." end
				seen[id] = true
				local valid, reason = validate(definitions[id].item, value)
				if not valid then return nil, reason, id end
				incoming[id] = value
			end
		end
		if not next(incoming) then return nil, "The file contains no supported settings." end
	end
	local changes, skipped = {}, 0
	-- Keep a stable order in the preview and in partial-write reports.
	for _, category in ipairs(categories) do
		for _, item in ipairs(category.items) do
			local value, definition = incoming[item.id], definitions[item.id]
			if value ~= nil and definition then
				if preserve_pon and definition.protected then
					skipped = skipped + 1
				elseif value ~= (current[item.id] or "") then
					table.insert(changes, { id = item.id, name = item.name or item.id, value = value })
				end
			end
		end
	end
	return { changes = changes, skipped = skipped }
end

return M
