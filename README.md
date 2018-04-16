The `timezones` module implements methods for working with timezones. It uses the [IANA timezone database](https://en.wikipedia.org/wiki/Tz_database) as a source for the timezone definitions.

Notable features:
- Works for both C and JS
- Compatible with the standard library - integrates into the `times` module
- Allows embeeding timezone data into executable
- Allows loading and switching timezone data during runtime
- Allows generating customized timezone data, containing only the timezones needed for your use case

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

let sweden = tzNames("SE")
echo sweden
# => @["Europe/Stockholm"]

let usa = tzNames("US")
echo usa
# => @[
#   "America/New_York",  "America/Adak",      "America/Phoenix",     "America/Yakutat",
#   "Pacific/Honolulu",  "America/Nome",      "America/Los_Angeles", "America/Detroit",
#   "America/Chicago",   "America/Boise",     "America/Juneau",      "America/Metlakatla",
#   "America/Anchorage", "America/Menominee", "America/Sitka",       "America/Denver"
# ]

let bangkok = tz"Asia/Bangkok"
echo bangkok.countries
# => @["TH", "KH", "LA", "VN"] 
```

## API
[Generated docs are available here](https://gulpf.github.io/timezones/timezones.html).

## Advanced usage
The timezone definitions from a [IANA timezone database](https://en.wikipedia.org/wiki/Tz_database) release are stored in a JSON file. This repo includes the currently latest release (2018d.json), but no guarantee is given as to how fast the bundled timezone database is updated when IANA releases a new version. The JSON file can either be embeeded into the executable (which is the default behavior), or be loaded at runtime.

If you want control over when the timezone definitions are updated, there are two
options:
- Embeed a custom JSON file
- Load a JSON file at runtime

Both options require you to generate the JSON file yourself. See [fetchjsontimezones](#fetchjsontimezones) for information on how to accomplish that.

To embeed a custom JSON file, simply pass `-d:timezonesPath={path}`, where `{path}` is the **absolute** path to the file.

To load a JSON definition at runtime, either of these procs can be used:
```nim
proc parseJsonTimezones*(content: string): TzData
proc loadJsonTimezones*(path: string): TzData # Not available for the JS backend
```
If you load the JSON timezones at runtime, it's likely that you don't need the bundled definitions. To disable the embeededing of the bundled JSON file, `-d:timezonesNoEmbeed` can be passed. This will reduce the size of the executable.

## fetchjsontimezones <a name="fetchjsontimezones"></a>

**NOTE**: The `fetchjsontimezones` tool isn't supported on Windows for now.

`fetchjsontimezones` is a command line tool for downloading IANA timezone database releases and converting them to the JSON format used by the `timezones` module. It's part of this repo and is installed by running `nimble install timezones`. Using `fetchjsontimezones` isn't required for using the `timezones` module, unless you want control over which timezone data is used.

Usage (`fetchjsontimezones --help`):
 ```
    fetchjsontimezones <version> # Download <version>, e.g '2018d'.

    --help                       # Print this help message

    --startYear:<year>           # Only store transitions starting from this year.
    --endYear:<year>             # Only store transitions until this year.
    --out:<file>, -o:<file>      # Write output to this file.
                                 # Defaults to './<version>.json'.
    --timezones:<zones>          # Only store transitions for these timezones.
    --regions:<regions>          # Only store transitions for these regions.
```

For example, `fetchjsontimezones 2017c --out:tzdata.json --startYear:1900 --endYear:2030` will create a tzdb file called `tzdata.json` containing timzone transitions for the years 1900 to 2030 generated from the `2017c` timezone database release.
