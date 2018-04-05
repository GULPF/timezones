# Package
import ospaths

version       = "0.2.0"
author        = "Oscar Nihlgård"
description   = "Timezone library compatible with the standard library"
license       = "MIT"

bin = @["timezones/fetchjsontimezones"]
skipDirs = @["tests"]
requires "nim >= 0.18.0"

# Tasks

task fetch, "Fetch the timezone database":
    exec "fetchjsontimezones " & paramStr(2) & " --out:" & (thisDir() / (paramStr(2) & ".json"))

task test, "Run the tests":
    let tzdataPath = thisDir() / "2018d.json"

    echo "\nRunning C tests (C)"
    echo "==============="
    exec "nim c --hints:off -r tests/tests.nim"

    echo "\nRunning tests (JS)"
    echo "================"
    exec "nim js -d:nodejs --hints:off -r tests/tests.nim"

    echo "\nTesting -d:timezonesPath (C)"
    echo "================"
    exec "nim c --hints:off -d:timezonesPath='" & tzdataPath & 
        "' -r tests/tests.nim"

    echo "\nTesting -d:timezonesPath (JS)"
    echo "================"
    exec "nim js -d:nodejs --hints:off -d:timezonesPath='" & tzdataPath & 
        "' -r tests/tests.nim"

task docs, "Generate docs":
    exec "nim doc -o:docs/timezones.html timezones.nim"