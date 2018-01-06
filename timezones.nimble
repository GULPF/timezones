# Package

version       = "0.1.0"
author        = "Oscar Nihlgård"
description   = "Timezone library compatible with the standard library"
license       = "MIT"

skipFiles = @["fetchtzdb.nim"]
bin = @["fetchtzdb"]

requires "nim >= 0.17.3"

# Tasks

task fetchtzdb, "Fetch the timezone database":
    exec "fetchtzdb " & paramStr(2) & " ./tzdb"