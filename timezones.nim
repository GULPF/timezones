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

template binarySeach(transitions: seq[Transition],
                     field: untyped, t: Time): Transition =
    var index = 0
    var count = transitions.len
    var step, pos: int
    while count != 0:
        step = count div 2
        pos = index + step
        if transitions[pos].field < t.toUnix:
            index = pos + 1
            count -= step + 1
        else:
            count = step
    transitions[index]

proc initTimezone(tz: InternalTimezone): Timezone =

    proc zoneInfoFromTz(adjTime: Time): ZonedTime {.locks: 0.} =
        let transition = tz.transitions.binarySeach(startAdj, adjTime)
        result.isDst = transition.isDst
        result.utcOffset = transition.utcOffset
        result.adjTime = adjTime

    proc zoneInfoFromUtc(time: Time): ZonedTime {.locks: 0.} =
        let transition = tz.transitions.binarySeach(startUtc, time)
        result.isDst = transition.isDst
        result.utcOffset = transition.utcOffset
        result.adjTime = time + initDuration(seconds = transition.utcOffset)

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

proc resolveTimezone(name: string): tuple[exists: bool, candidate: string] =
    var bestCandidate: string
    var bestDistance = high(int)
    for tz in staticDatabase.timezones:
        if tz.name == name:
            return (true, "")
        else:
            let distance = editDistance(tz.name, name)
            if distance < bestDistance:
                bestCandidate = tz.name
                bestDistance = distance
    return (false, bestCandidate)

proc timezoneImpl(name: string): Timezone =
    # xxx make it a hashtable or something
    for tz in timezoneDatabase.timezones:
        if tz.name == name:
            result = initTimezone(tz)

proc timezone*(name: string): Timezone {.inline.} =
    ## Create a timezone using a name from the IANA timezone database.
    runnableExamples:
        let sweden = timezone("Europe/Stockholm")
        let dt = initDateTime(1, mJan, 1850, 00, 00, 00, sweden)
        doAssert $dt == "1850-01-01T00:00:00-01:12"

    result = timezoneImpl name

proc timezone*(name: static[string]): Timezone {.inline.} =
    ## Create a timezone using a name from the IANA timezone database.
    runnableExamples:
        let sweden = timezone("Europe/Stockholm")
        let dt = initDateTime(1, mJan, 1850, 00, 00, 00, sweden)
        doAssert $dt == "1850-01-01T00:00:00-01:12"

    const resolved = name.resolveTimezone
    when not resolved.exists:
        {.fatal: "Timezone not found: '" & name &
            "'.\nDid you mean '" & resolved.candidate & "'?".}
    
    result = timezoneImpl name

const DatabaseYear* = staticDatabase.version.year
const DatabaseRelease* = staticDatabase.version.release
const DatabaseVersion* = $DatabaseYear & DatabaseRelease