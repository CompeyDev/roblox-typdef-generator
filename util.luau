local stdio = require("@lune/stdio")
local datetime = require("@lune/datetime")

local function __log(kind: "info" | "warn" | "error", caller: string, msg: string)
	print(
		`{stdio.style("dim") .. datetime.now():formatLocalTime("%Y-%m-%d %H:%M:%S%.3fZ") .. stdio.style("reset")} [{stdio.style("bold") .. kind .. stdio.style("reset")}][::{stdio.style("bold") .. caller .. stdio.style("reset")}]`,
		msg
	)
end

return {
	logger = setmetatable({}, {
		__index = function(_, k)
			local scope

			if k == "info" then
				scope = stdio.color("green") .. k .. stdio.color("reset")
			end

			if k == "warn" then
				scope = stdio.color("yellow") .. k .. stdio.color("reset")
			end

			if k == "error" then
				scope = stdio.color("red") .. k .. stdio.color("reset")
			end

			return function(caller: string, msg: string)
				__log(scope or "unknown", caller, msg)
			end
		end,
	}),
}
