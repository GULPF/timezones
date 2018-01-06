import times
import strutils

type
    Transition = object
        startUtc: int64
        startAdj: int64
        isDst: bool
        utcOffset: int32

    InternalTimezone = object
        transitions: seq[Transition]
        name: string

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

let zonesTxt {.compileTime.} = staticRead("./tzdb/zones.txt")
var tzBuffer {.compileTime.} = newSeq[InternalTimezone]()
var currentTz {.compileTime.} = InternalTimezone(
    transitions: newSeq[Transition]())

# Load timezone data from file during compilation.
# xxx very slow, need to use a binary format instead.
static:
    for line in zonesTxt.splitLines:
        if line == "": continue
        let tokens = line.splitWhitespace
        
        if tokens[0] != currentTz.name:
            echo "Parsing ", tokens[0]
            if not currentTz.name.isNil:
                tzBuffer.add currentTz
            currentTz = InternalTimezone(
                name: tokens[0],
                transitions: newSeq[Transition]())

        currentTz.transitions.add Transition(
            startUtc: parseInt(tokens[1]),
            startAdj: parseInt(tokens[2]),
            isDst: parseBool(tokens[3]),
            utcOffset: parseInt(tokens[4]).int32)

    if not currentTz.name.isNil:
        tzBuffer.add currentTz

const timezoneDatabase = tzBuffer

proc timezone(name: string): Timezone =
    # xxx make it a hashtable or something
    for tz in timezoneDatabase:
        if tz.name == name:
            result = initTimezone(tz)

let tz = staticOffset(hours = -2, minutes = -30)
let dt = initDateTime(1, mJan, 2000, 12, 00, 00)
    .inZone(timezone("Europe/Stockholm"))
echo dt     # 2000-01-01T12:00:00+02:30
echo dt.utc # 2000-01-01T09:30:00+00:00