local fs = require("@lune/fs")
local json_decode = function(data)
	return require("@lune/serde").decode("json", data)
end

local codegen = {}

-- TODO: Finish types

function codegen.generate_types(path: string)
	local contents = fs.readFile(path)
	-- print(contents)
	local json: {
		[string]: {
			base_type: string,

			tags: { string },
		},
	} = json_decode(contents)

	-- print(json)
end

return codegen
