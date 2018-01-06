import times
import strutils
import timezones/private/binformat

const tzdbpath {.strdefine.} = "./tzdb/2017c.bin"

proc initTimezone(offset: int): Timezone =

    proc zoneInfoFromTz(adjTime: Time): ZonedTime {.locks: 0.} =
        result.isDst = false
        result.utcOffset = offset
        result.adjTime = adjTime

    proc zoneInfoFromUtc(time: Time): ZonedTime {.locks: 0.}=
        result.isDst = false
        result.utcOffset = offset
        result.adjTime = time + initDuration(seconds = offset)

    result.name = ""
    result.zoneInfoFromTz = zoneInfoFromTz
    result.zoneInfoFromUtc = zoneInfoFromUtc

proc initTimezone(tz: InternalTimezone): Timezone =

    # xxx need binary search  

    proc zoneInfoFromTz(adjTime: Time): ZonedTime {.locks: 0.} =
        var activeTrans = tz.transitions[0]
        let unix = adjTime.toUnix
        for idx in 1..high(tz.transitions):
            if tz.transitions[idx].startAdj < unix:
                activeTrans = tz.transitions[idx - 1]

        result.isDst = activeTrans.isDst
        result.utcOffset = activeTrans.utcOffset
        result.adjTime = adjTime

    proc zoneInfoFromUtc(time: Time): ZonedTime {.locks: 0.} =
        var activeTrans = tz.transitions[0]
        let unix = time.toUnix
        for idx in 1..high(tz.transitions):
            if tz.transitions[idx].startUtc < unix:
                activeTrans = tz.transitions[idx - 1]

        result.isDst = activeTrans.isDst
        result.utcOffset = activeTrans.utcOffset
        result.adjTime = time + initDuration(seconds = activeTrans.utcOffset)

    result.name = tz.name
    result.zoneInfoFromTz = zoneInfoFromTz
    result.zoneInfoFromUtc = zoneInfoFromUtc

proc staticOffset*(hours, minutes, seconds: int = 0): Timezone =
    ## Create a timezone using a static offset from UTC.
    runnableExamples:
        import times
        let tz = staticOffset(hours = -2, minutes = -30)
        let dt = initDateTime(1, mJan, 2000, 12, 00, 00, tz)
        doAssert $dt == "2000-01-01T12:00:00+02:30"

    let offset = hours * 3600 + minutes * 60 + seconds
    result = initTimezone(offset)

const staticDatabase = binformat.staticReadFromString(staticRead tzdbpath)
let timezoneDatabase = staticDatabase.finalize

proc timezoneExists(name: string): bool =
    for tz in staticDatabase.timezones:
        if tz.name == name:
            return true

proc timezone*(name: string): Timezone =
    ## Create a timezone using a name from the IANA timezone database.
    runnableExamples:
        let sweden = timezone("Europe/Stockholm")
        let dt = initDateTime(1, mJan, 1850, 00, 00, 00, sweden)
        doAssert $dt == "1850-01-01T00:00:00-01:12"

    # xxx make it a hashtable or something
    for tz in timezoneDatabase.timezones:
        if tz.name == name:
            result = initTimezone(tz)

proc timezone*(name: static[string]): Timezone {.inline.} =
    ## Create a timezone using a name from the IANA timezone database.
    runnableExamples:
        let sweden = timezone("Europe/Stockholm")
        let dt = initDateTime(1, mJan, 1850, 00, 00, 00, sweden)
        doAssert $dt == "1850-01-01T00:00:00-01:12"

    when not name.timezoneExists:
        {.fatal: "Timezone not found: '" & name & "'".}

const DatabaseYear* = staticDatabase.version.year
const DatabaseRelease* = staticDatabase.version.release
const DatabaseVersion* = $DatabaseYear & DatabaseRelease