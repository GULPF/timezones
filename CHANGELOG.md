Version 0.4.0
=============

- Updated database to version 2018g
- `countries(db, tzName)` and `location(db, tzName)` no longer throws when `tzName` doesn't exist in the database.
- The name of static offset timezones have been changed to `±HH:MM:SS` or `±HH:MM` (was: `STATIC[±HH:MM:SS]` or `STATIC[±HH:MM]`).
- `tz(tzName)` now accepts static offsets on the form `±HH:MM:SS` or `±HH:MM` as well as the special string `LOCAL` for the local timezone.
- `Dms` and `Coordinates` are now objects instead of tuples