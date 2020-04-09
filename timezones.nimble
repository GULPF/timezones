import timezones / private / tzversion

version       = "0.5.2"
author        = "Oscar Nihlgård"
description   = "Timezone library compatible with the standard library"
license       = "MIT"

bin = @["timezones/fetchjsontimezones"]
installDirs = @["timezones"]
installFiles = @[Version & ".json", "timezones.nim"]
requires "nim >= 0.19.9"

# Tasks

task fetch, "Fetch the timezone database":
    exec "nim c -d:timezonesNoEmbeed -r timezones/fetchjsontimezones " &
        Version &  " --out:" & thisDir() & "/" & Version & ".json"

task test, "Run the tests":
    echo thisDir()
    let tzdataPath = thisDir() & "/" & Version & ".json"

    # Run tests with various backends and options

    echo "\nRunning tests (C)"
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

    rmFile "tests/tests"
    rmFile "tests/tests.js"

    # Test `fetchjsontimezones`

    exec "nim c --hints:off -r timezones/fetchjsontimezones " &
        "2018g --out:testdata.json"
    rmFile "testdata.json"
    rmFile "timezones/fetchjsontimezones"

task docs, "Generate docs":
    exec "nim doc -o:docs/timezones.html timezones.nim"
    exec "nim doc -o:docs/posixtimezones.html timezones/posixtimezones.nim"