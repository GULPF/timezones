The `timezones` module implements methods for working with timezones. It uses the [IANA timezone database](https://en.wikipedia.org/wiki/Tz_database) as a source for the timezone definitions. It's still in an early stage and the API is likely to change. Both the C backend and the JS backend is supported.

## Usage
```nim
import times
import timezones

let tz = staticTz(hours = -2, minutes = -30)
echo initDateTime(1, mJan, 2000, 12, 00, 00, tz)
# => 2000-01-01T12:00:00+02:30

let stockholm = tz"Europe/Stockholm"
echo initDateTime(1, mJan, 1850, 00, 00, 00, stockholm)
# => 1850-01-01T00:00:00+01:12

let sweden = tzNames(cc"SE")
echo sweden
# => @["Europe/Stockholm"]

let usa = tzNames(cc"US")
echo usa
# => @[
#   "America/New_York",  "America/Adak",      "America/Phoenix",     "America/Yakutat",
#   "Pacific/Honolulu",  "America/Nome",      "America/Los_Angeles", "America/Detroit",
#   "America/Chicago",   "America/Boise",     "America/Juneau",      "America/Metlakatla",
#   "America/Anchorage", "America/Menominee", "America/Sitka",       "America/Denver"
# ]

let bangkok = tz"Asia/Bangkok"
echo bangkok.countries
# => @[cc"TH", cc"KH", cc"LA", cc"VN"]
```

## API
todo

## How does it work
The timezone definitions from a IANA timezone database release are stored in a JSON file. This repo includes the currently latest release (2018c.json), but no guarantee is given as to how fast the bundled timezone database is updated when IANA releases a new version. The JSON file can either be embeeded into the executable (which is the default behavior), or be loaded at runtime.

If you want control over when the timezone definitions are updated, there are two
options:
- Embeed a custom JSON file
- Load a JSON file at runtime

Both options require you to generate the JSON file yourself. See fetchjsontimezones for information on how to accomplish that.

To embeed a custom JSON file, simply pass `-d:timezonesPath={path}>`, where `{path}` is the absolute path to the file.

To load a JSON definition at runtime, either of these procs can be used:
```nim
proc parseJsonTimezones*(content: string): OlsonDatabase
proc loadJsonTimezones*(path: string): OlsonDatabase # Not for the JS backend
```
If you load the JSON timezones at runtime, it's likely that you don't need to the bundled definitions. To disable the embeeded, `-d:timezonesNoEmbeed` can be passed.

## fetchjsontimezones

Usage (`fetchjsontimezones --help`):
 ```
    --help                  # Print this help message

    --startYear:<year>      # Only store transitions starting from this year.
    --endYear:<year>        # Only store transitions until this year.
    --out:<file>, -o:<file> # Write output to this file.
    --timezones:<zones>     # Only use these timezones.
    --regions:<regions>     # Only use these regions.
```

For example, `fetchjsontimezones 2017c --out:2017c.bin --startYear:1900 --endYear:2030` will create a tzdb file called `2017c.bin` containing
timzone transitions for the years 1900 to 2030 generated from the `2017c` timezone database release.

The `fetchjsontimezones` tool is not supported on Windows.

## Using a custom tzdb file
Of course, downloading your own timezone file is not very useful unless you can instruct `timezones` to use it instead of the bundled one.
To indicate that a different timezone file should be used, send the __absolute__ path to the file as a command line define: `--define:embedTzdb=<path>`.