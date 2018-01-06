The `timezones` module implements methods for working with timezones. It uses the [IANA time zone database](https://en.wikipedia.org/wiki/Tz_database) as a source for the timezone transitions. It's still in an early stage
and the API is likely to change.

It doesn't work with Nim devel yet, https://github.com/nim-lang/Nim/pull/7033 is required.

#### Usage
```nim
import times
import timezones

let tz = staticOffset(hours = -2, minutes = -30)
echo initDateTime(1, mJan, 2000, 12, 00, 00, tz)
# => 2000-01-01T12:00:00+02:30

let sweden = timezone("Europe/Stockholm")
echo initDateTime(1, mJan, 1850, 00, 00, 00, sweden)
# => 1850-01-01T00:00:00-01:12
```

#### TODO
- Documentation
- Tests
- Static validation of timezone names
