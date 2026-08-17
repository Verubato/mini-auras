-- Perfy's analyzer needs Lua 5.3 or newer, and the only one on this machine is the runtime
-- inside lua-language-server. Its Main.lua expects to be started from its own directory and
-- writes the stack files to the working directory, so both are set here before handing over.

local analyzerDir, outDir = arg[1], arg[2]
if not analyzerDir or not outDir or not arg[3] then
	print("Usage: RunAnalyzer.lua <analyzer dir> <output dir> <saved variables file> [analyzer args]")
	return
end

package.path = analyzerDir .. "/?.lua;" .. package.path

local fs = require "bee.filesystem"
fs.current_path(fs.path(outDir))

local main = assert(loadfile(analyzerDir .. "/Main.lua"))
main(table.unpack(arg, 3, #arg))
