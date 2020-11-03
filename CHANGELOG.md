Version 0.5.4 (2020-11-03)
=============
- Updated bundled timezone database to version 2020d
- Fix bug with `timezones/posixtimezones` in release mode
- Fix issue with `fetchjsontimexones` for newer IANA timezone releases

Version 0.5.3 (2020-06-20)
=============
- Updated bundled timezone database to version 2020a
- Fix issue preventing the library from being installable on Windows

Version 0.5.2 (2020-04-09)
=============
- Updated bundled timezone database to version 2019c
- Fix support for latest Nim

Version 0.5.1 (2019-09-07)
=============
- Updated bundled timezone database to version 2019b

Version 0.5.0 (2019-02-15)
=============
This release is a nearly complete rewrite of the library. No attempt at backwards compatibility has been made, but the API should now be stable moving forwards.

Notable additions:
- A new `timezones/posixtimezones` module has been added for handling the system timezones on posix systems.
- A new `timezones.TimezoneInfo` type has been added which represents
a timezone + additional meta data.
- Possibility of setting the default timezone db with `setDefaultTzDb`.
- Updated bundled timezone database to version 2018i

Version 0.4.0 (2018-11-05)
=============

- `countries(db, tzName)` and `location(db, tzName)` no longer throws when `tzName` doesn't exist in the database.
- The name of static offset timezones have been changed to `±HH:MM:SS` or `±HH:MM` (was: `STATIC[±HH:MM:SS]` or `STATIC[±HH:MM]`).
- `tz(tzName)` now accepts static offsets on the form `±HH:MM:SS` or `±HH:MM` as well as the special string `LOCAL` for the local timezone.
- `Dms` and `Coordinates` are now objects instead of tuples
- Updated bundled timezone database to version 2018g