The `timezones` module implements methods for working with timezones. It uses the [IANA time zone database](https://en.wikipedia.org/wiki/Tz_database) as a source for the timezone transitions. It's still in an early stage
and the API is likely to change.

It doesn't work with Nim devel yet, https://github.com/nim-lang/Nim/pull/7033 is required.

## Usage
```nim
import times
import timezones

let tz = staticTz(hours = -2, minutes = -30)
echo initDateTime(1, mJan, 2000, 12, 00, 00, tz)
# => 2000-01-01T12:00:00+02:30

let sweden = tz"Europe/Stockholm"
echo initDateTime(1, mJan, 1850, 00, 00, 00, sweden)
# => 1850-01-01T00:00:00+01:12

# Compile time validation of timezone names
let invalid = tz"Europe/Stokholm"
# Error: Timezone not found: 'Europe/Stokholm'.
# Did you mean 'Europe/Stockholm'?
```

## tzdb
This package also includes a tool called `tzdb` for fetching the timezone database and converting it to
the binary format used by `timezones`. This is not necessary for normal use since the package bundles the latest
release (stored in the file `/tzdb/2017c.bin`), but it can be used to gain control over when the database is updated.
Usage: `tzdb <version> <dir>`. For example, `tzdb 2014b .` will download version 2014b and save it to `2014b.bin` in the current directory.

The `tzdb` tool is not supported on Windows.

## Using a custom timezone file
Of course, downloading your own timezone file is not very useful unless you can instruct `timezones` to use it instead of the bundled one.
To indicate that a different timezone file should be used, send the absolute path to the file as a command line define: `--define:tzdb=<path>`.