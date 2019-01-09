# Timezones

A library for working with timezones. It uses the [IANA timezone database](https://en.wikipedia.org/wiki/Tz_database) as a source for the timezone definitions. Both the C based backends and the JS backend is supported.

## Installation

Timezones is available on Nimble:
```
nimble install timezones
```

## Usage
```nim
import times
import timezones

# Create a timezone representing a static offset from UTC.
let zone = tz"+02:30"
echo initDateTime(1, mJan, 2000, 12, 00, 00, zone)
# => 2000-01-01T12:00:00+02:30

# Static offset timezones can also be created with the proc ``staticTz``,
# which is preferable if the offset is only known at runtime.
doAssert zone == staticTz(hours = -2, minutes = -30)

# Create a timezone representing a timezone in the IANA timezone database.
let stockholm = tz"Europe/Stockholm"
echo initDateTime(1, mJan, 1850, 00, 00, 00, stockholm)
# => 1850-01-01T00:00:00+01:12

# Like above, but returns a `TimezoneInfo` object which contains some
# extra metadata.
let stockholmInfo = tzInfo"Europe/Stockholm"
# Countries are specified with it's two character country code,
# see ISO 3166-1 alpha-2.
doAssert stockholmInfo.countries == @["SE"]
doAssert stockholmInfo.timezone == stockholm

# Note that some timezones are used by multiple countries.
let bangkok = tzInfo"Asia/Bangkok"
doAssert bangkok.countries == @["TH", "KH", "LA", "VN"]
```

## API
- [Generated docs for timezones module](https://gulpf.github.io/timezones/timezones.html).
- [Generated docs for posixtimezones module](https://gulpf.github.io/timezones/posixtimezones.html).

## Advanced usage
The timezone definitions from a [IANA timezone database](https://en.wikipedia.org/wiki/Tz_database) release are stored in a JSON file. This repo includes the currently latest release, but no guarantee is given as to how fast the bundled timezone database is updated when IANA releases a new version. The JSON file can either be embeeded into the executable (which is the default behavior), or be loaded at runtime.

If you want control over when the timezone definitions are updated, there are two options:
- Embeed a custom JSON file
- Load a JSON file at runtime

Both options require you to generate the JSON file yourself. See [fetchjsontimezones](#fetchjsontimezones) for information on how to accomplish that.

To embeed a custom JSON file, simply pass `-d:timezonesPath={path}>`, where `{path}` is the **absolute** path to the file.

To load a JSON definition at runtime, either of these procs can be used:
```nim
proc parseJsonTimezones*(content: string): TzData
proc loadJsonTimezones*(path: string): TzData # Not available for the JS backend
```
If you load the JSON timezones at runtime, it's likely that you don't need the bundled definitions. To disable the embeededing of the bundled JSON file, `-d:timezonesNoEmbeed` can be passed.

## fetchjsontimezones <a name="fetchjsontimezones"></a>

**NOTE**: The `fetchjsontimezones` tool isn't supported on Windows for now.

`fetchjsontimezones` is a command line tool for downloading IANA timezone database releases and converting them to the JSON format used by the `timezones` module. It's part of this repo and is installed by running `nimble install timezones`. Using `fetchjsontimezones` isn't required for using the `timezones` module, but it's needed to load timezone data during runtime.

Usage (`fetchjsontimezones --help`):
 ```
    fetchjsontimezones <version> # Download <version>, e.g '2018d'.

    --help                       # Print this help message
    --out:<file>, -o:<file>      # Write output to this file.
                                 # Defaults to './<version>.json'.
    --timezones:<zones>          # Only store transitions for these timezones.
    --regions:<regions>          # Only store transitions for these regions.
```

For example, `fetchjsontimezones 2017c --out:tzdata.json --regions:"europe america"` will create a timezone data file called `tzdata.json` containing timzeone transitions for the regions 'europe' and 'america' generated from the `2017c` timezone database release.
