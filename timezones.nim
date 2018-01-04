import times
import strutils

proc initTimezone(offset: int): Timezone =
    proc zoneInfoFromTz(adjTime: Time): ZonedTime =
        result.isDst = false
        result.utcOffset = offset
        result.adjTime = adjTime

    proc zoneInfoFromUtc(time: Time): ZonedTime =
        result.isDst = false
        result.utcOffset = offset
        result.adjTime = time + initDuration(seconds = offset)

    result.name = "STATIC"
    result.zoneInfoFromTz = zoneInfoFromTz
    result.zoneInfoFromUtc = zoneInfoFromUtc

proc staticOffset*(hours, minutes, seconds: int = 0): Timezone =
    let offset = hours * 3600 + minutes * 60 + seconds
    result = initTimezone(offset)
