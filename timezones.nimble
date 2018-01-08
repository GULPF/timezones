# Package

version       = "0.1.0"
author        = "Oscar Nihlgård"
description   = "Timezone library compatible with the standard library"
license       = "MIT"

skipFiles = @["tzdb.nim", "tests.nim"]
bin = @["tzdb"]

requires "nim >= 0.17.3"

# Tasks

task tzdb, "Fetch the timezone database":
    exec "tzdb " & paramStr(2) & " ./tzdb"