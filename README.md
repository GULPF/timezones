The `timezones` module implements methods for working with timezones. It uses the [IANA time zone database](https://en.wikipedia.org/wiki/Tz_database) as a source for the timezone transitions. It's still in an early stage
and the API is likely to change.

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
release (stored in the file `/bundled_tzdb_file/2017c.bin`), but it can be used to gain control over when the database is updated.

Usage (`tzdb --help`):
 ```
Commands:
    dump  <file>          # Print info about a tzdb file
    fetch <version>       # Download and process a tzdb file
    diff  <file1> <file2> # Compare two tzdb files (not implemented)
    --help                # Print this help message

Fetch parameters:
    --startYear:<year>    # Only store transitions starting from this year.
    --endYear:<year>      # Only store transitions until this year.
    --out:<file>          # Write output to this file.
    --timezones:<zones>   # Only use these timezones.
    --regions:<regions>   # Only use these regions.
    --json                # Store transitions as JSON (required for JS support).
```

For example, `tzdb fetch 2017c --out:2017c.bin --startYear:1900 --endYear:2030` will create a tzdb file called `2017c.bin` containing
timzone transitions for the years 1900 to 2030 generated from the `2017c` timezone database release.

The `tzdb` tool is not supported on Windows.

## Using a custom tzdb file
Of course, downloading your own timezone file is not very useful unless you can instruct `timezones` to use it instead of the bundled one.
To indicate that a different timezone file should be used, send the __absolute__ path to the file as a command line define: `--define:embedTzdb=<path>`.