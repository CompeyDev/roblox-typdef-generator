local net = require("@lune/net")
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local logger = require("util").logger

local DUMP_URL = "https://github.com/MaximumADHD/Roblox-Client-Tracker/raw/roblox/API-Dump.txt"

function download_dump(): string
	local TARGET = "download_dump"

	local resp = net.request(DUMP_URL)

	if not resp.ok then
		logger.error(TARGET, `Response returned code {resp.statusCode} != 200`)
		process.exit(1)
	end

	if not fs.isDir("dumps") then
		xpcall(function()
			fs.writeDir("dumps")
		end, function()
			logger.error(TARGET, "Failed to create dumps directory")
			process.exit(1)
		end)
	end

	local dump_path = `dumps/dump_{string.format("0x%x", #resp.body)}.txt`

	xpcall(function()
		fs.writeFile(dump_path, resp.body)
	end, function()
		logger.error(TARGET, `Failed to write latest dump file at {dump_path}`)
		process.exit(1)
	end)

	logger.info(TARGET, `Successfully downloaded dump file to {dump_path}!`)

	-- Hardcoded cuz max's client tracker had a breaking change
	return parse_dump("dumps/dump_0x8317d.txt")
end

-- TODO: Handle enums
function parse_dump(path: string)
	local TARGET = "parse_dump"
	local IDENT = "	"

	local function get_tags(kind: "Class" | "Property", tokens, name: string?)
		local tags = {}

		if kind == "Class" then
			for _, tag in pairs({ table.unpack(tokens, 5, #tokens) }) do
				logger.info(TARGET, `Got tag {tag} for {kind} {name or "unknown"}`)

				if not (tag:sub(1, 1) == "[" and tag:sub(-1) == "]") then
					logger.error(TARGET, "Expected tag to be enclosed in `[]`")
					process.exit(1)
				end

				local inner = tag:sub(2, #tag - 1)

				table.insert(tags, inner)
			end
		end

		if kind == "Property" then
			for _, tag in pairs({ table.unpack(tokens, 4, #tokens) }) do
				logger.info(TARGET, `Got tag {tag} for {kind} {name or "unknown"}`)

				local inner

				if not (tag:sub(1, 1) == "[" and tag:sub(-1) == "]") then
					logger.warn(TARGET, "Tag not enclosed in `[]`")

					inner = tag
				else
					inner = tag:sub(2, #tag - 1)
				end

				table.insert(tags, inner)
			end
		end

		return tags
	end

	local contents = fs.readFile(path)
	local lines = (function(raw)
		-- Sanitize and remove return carriages
		local sanitized = raw

		for k, v in sanitized do
			sanitized[k] = v:gsub("\r", "")
		end

		return sanitized
	end)(contents:split("\n"))

	local parsed = {}

	local parent_node: string
	for pos, line in lines do
		local tokens = line:split(" ")

		if tokens[1] == "Class" then
			local class_name = tokens[2]

			parsed[class_name] = {
				base_type = (function()
					if tokens[3] == ":" then
						return tokens[4]
					end

					logger.error(TARGET, `Expected {pos}[3] to be \`:\``)
					process.exit(1)

					return
				end)(),

				tags = get_tags("Class", tokens, class_name),
			}

			parent_node = class_name
		end

		if tokens[1] == "Enum" then
			local enum_name = tokens[2]

			parsed[enum_name .. `\{{tokens[1]}\}`] = {
				kind = tokens[1],
			}

			parent_node = enum_name
		end

		if tokens[1]:find(IDENT) then
			local child_type = tokens[1]:gsub(IDENT, "")
			parsed[parent_node].children = {}

			if child_type == "Property" then
				table.insert(parsed[parent_node].children, {
					kind = child_type,
					type = tokens[2],
					-- FIXME: Name is sometimes incorrect
					name = tokens[3]:gsub(parent_node .. ".", "", 1),
					tags = get_tags(child_type, tokens, tokens[3]),
				})
			end

			if child_type == "EnumItem" then
				-- [1] => name
				-- [2] => always ":"
				-- [3] => position
				local sub_tokens = { table.unpack(tokens, 2, 4) }
				local name = sub_tokens[1]:gsub(parent_node .. ".", 1)

				if sub_tokens[2] ~= ":" then
					logger.error(TARGET, `Expected delim \`:\` between enum item and position for enum {name}`)
					process.exit(1)
				end

				parsed[parent_node].children[sub_tokens[3]] = name
			end

			if child_type == "Function" then
				local sub_tokens = tokens[3]:split(":")

				if sub_tokens[1] ~= parent_node then
					logger.error(TARGET, `Expected parent class for function to be {parent_node} for {sub_tokens[1]}`)
					process.exit(1)
				end

				-- may not always be 3 - 4
				local func_decl = table.concat({ table.unpack(tokens, 3, 4) }, " ")
				local cur_offset = 4

				while not (func_decl:sub(-1) == ")" or func_decl:sub(-1) == "}" or func_decl:sub(-1) == "]") do
					cur_offset += 1
					func_decl = table.concat({ table.unpack(tokens, 3, cur_offset) }, " ")
				end

				logger.info(TARGET, `Got {child_type} {func_decl}`)

				-- Strip the parent class part
				func_decl = func_decl:gsub(`{parent_node}:`, "")

				table.insert(parsed[parent_node].children, {
					kind = child_type,
					ret = tokens[2],
					name = func_decl:gsub("%b()", ""),
					params = (function()
						local args = table.pack(func_decl:match("%b()"))

						if args ~= nil and args[1] ~= nil then
							local params = table.pack(args[1]:sub(2, #args[1] - 1))[1]:split(", ")
							local parsed_params = {}

							for _, param in params do
								if param ~= "" then
									-- [1] => type
									-- [2] => name

									local parts = param:split(" ")

									table.insert(parsed_params, {
										name = parts[2],
										type = parts[1]:gsub(parts[2] .. " ", ""),
									})

									logger.info(TARGET, `Got param {parts[1]} for class {func_decl}`)
								end
							end

							return parsed_params
						end

						return {}
					end)(),
				})
			end

			-- Code down here is very similar to the code that handles the Function case
			-- TODO: Reduce boilerplate here
			if child_type == "Event" then
				local sub_tokens = tokens[2]:split(".")

				if sub_tokens[1] ~= parent_node then
					logger.error(TARGET, `Expected parent class for function to be {parent_node}`)
					process.exit(1)
				end

				local func_decl = table.concat({ table.unpack(tokens, 2, 4) }, " ")

				local cur_offset = 5

				while not (func_decl:sub(-1) == ")" or func_decl:sub(-1) == "}" or func_decl:sub(-1) == "]") do
					cur_offset += 1
					func_decl = table.concat({ table.unpack(tokens, 2, cur_offset) }, " ")
				end

				logger.info(TARGET, `Got {child_type} {func_decl}`)

				-- Strip the parent class part
				func_decl = func_decl:gsub(`{parent_node}.`, "")

				table.insert(parsed[parent_node].children, {
					kind = child_type,
					name = func_decl:gsub("%b()", ""),
					params = (function()
						local args = table.pack(func_decl:match("%b()"))

						if args ~= nil and args[1] ~= nil then
							local params = table.pack(args[1]:sub(2, #args[1] - 1))[1]:split(", ")

							local parsed_params = {}

							for _, param in params do
								if param ~= "" then
									local parts = param:split(" ")

									-- Some special edge cases where params have no type provided
									-- IK that this is a shitty way to do it but you can literally cry
									if
										func_decl == "AncestryChanged(child, parent)"
										or func_decl == "ChildAdded(child)"
										or func_decl == "ChildRemoved(child)"
										or func_decl == "DescendantAdded(descendant)"
										or func_decl == "DescendantRemoving(descendant)"
										or func_decl == "LocalSimulationTouched(part) [Deprecated]"
										or func_decl == "StoppedTouching(otherPart) [Deprecated]"
										or func_decl == "TouchEnded(otherPart)"
										or func_decl == "Touched(otherPart)"
									then
										table.insert(parsed_params, {
											name = param,
											type = "any",
										})
									elseif func_decl == "Chatted(string message, recipient)" then
										table.insert(parsed_params, {
											name = (param:match("message") and "string") or "any",
											type = "any",
										})
									elseif
										func_decl
										== "FriendStatusChanged(player, Enum.FriendStatus friendStatus) {RobloxScriptSecurity}"
									then
										table.insert(parsed_params, {
											name = (param:match("friendStatus") and "Enum.FriendStatus") or "any",
											type = "any",
										})
									else
										table.insert(parsed_params, {
											name = parts[2],
											type = parts[1]:gsub(parts[2] .. " ", ""),
										})
									end

									logger.info(TARGET, `Got param {parts[1]} for class {func_decl}`)
								end
							end

							return parsed_params
						end

						return {}
					end)(),
				})
			end
		end
	end

	local parsed_dump_path = path:gsub("txt", "json")

	xpcall(function()
		fs.writeFile(parsed_dump_path, serde.encode("json", parsed))

		logger.info(TARGET, `Successfully wrote parsed dump to path {parsed_dump_path}!`)
	end, function()
		logger.error(TARGET, "Failed to write parsed dump file")
		process.exit(1)
	end)

	return parsed_dump_path
end

return download_dump
