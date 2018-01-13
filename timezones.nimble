# Package

version       = "0.1.0"
author        = "Oscar Nihlgård"
description   = "Timezone library compatible with the standard library"
license       = "MIT"

skipFiles = @["timezones/tzdb.nim", "timezones/tzdb.nim.cfg"]
skipDirs = @["tests"]
bin = @["timezones/tzdb"]

requires "nim >= 0.17.3"

# Tasks

task tzdb, "Fetch the timezone database":
    exec "tzdb fetch " & paramStr(2) & " --out:./bundled_tzdb_files/" & paramStr(2) & ".bin"
    exec "tzdb fetch " & paramStr(2) & " --json --out:./bundled_tzdb_files/" & paramStr(2) & ".json.bin"

task test, "Run the tests":
    echo "\nRunning C tests"
    echo "==============="
    exec "nim c --hints:off -r tests/tests.nim"
    echo "\nRunning JS tests"
    echo "================"
    exec "nim js -r --hints:off tests/tests.nim"
    