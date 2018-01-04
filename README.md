This project is currently just a stub, but it will eventually make it possible to use timezones from the Olson database in combination with the `times` module from the standard library. For now it only exports a single proc for creating a timezone using a static UTC offset:

```nim
import times
import timezones

let tz = staticOffset(hours = -2, minutes = -30)
let dt = initDateTime(1, mJan, 2000, 12, 00, 00).inZone(tz)
echo dt     # 2000-01-01T12:00:00+02:30
echo dt.utc # 2000-01-01T09:30:00+00:00
```