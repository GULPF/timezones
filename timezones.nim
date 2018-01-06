import times
import strutils
import "private/binformat"

const tzdbpath {.strdefine.} = "./tzdb/2017c.bin"

proc initTimezone(offset: int): Timezone =

    proc zoneInfoFromTz(adjTime: Time): ZonedTime =
        result.isDst = false
        result.utcOffset = offset
        result.adjTime = adjTime

    proc zoneInfoFromUtc(time: Time): ZonedTime =
        result.isDst = false
        result.utcOffset = offset
        result.adjTime = time + initDuration(seconds = offset)

    result.name = ""
    result.zoneInfoFromTz = zoneInfoFromTz
    result.zoneInfoFromUtc = zoneInfoFromUtc

proc initTimezone(tz: InternalTimezone): Timezone =

    # xxx need binary search  

    proc zoneInfoFromTz(adjTime: Time): ZonedTime =
        var activeTrans = tz.transitions[0]
        let unix = adjTime.toUnix
        for idx in 1..high(tz.transitions):
            if tz.transitions[idx].startAdj < unix:
                activeTrans = tz.transitions[idx - 1]

        result.isDst = activeTrans.isDst
        result.utcOffset = activeTrans.utcOffset
        result.adjTime = adjTime

    proc zoneInfoFromUtc(time: Time): ZonedTime =
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
    let offset = hours * 3600 + minutes * 60 + seconds
    result = initTimezone(offset)

const content = staticRead tzdbpath
let timezoneDatabase = binformat.readFromString content

proc timezone*(name: string): Timezone =
    # xxx make it a hashtable or something
    for tz in timezoneDatabase.timezones:
        if tz.name == name:
            result = initTimezone(tz)

proc castToInt32(str: string): int32 {.compileTime.} =
    # Casting is very limited in the VM, this works for our simple use case.
    when cpuEndian == littleEndian:
        result = (str[3].int32 shl 24) or
            (str[2].int32 shl 16) or (str[1].int32 shl 8) or str[0].int32
    else:
        result = (str[0].int32 shl 24) or
            (str[1].int32 shl 16) or (str[2].int32 shl 8) or str[3].int32

const DatabaseYear* = castToInt32(content[4..7])
const DatabaseRelease* = content[8]
const DatabaseVersion* = $DatabaseYear & DatabaseRelease