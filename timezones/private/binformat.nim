import streams
import times
type
    Transition* = object {.packed.}
        startUtc*: int64  ## Seconds since 1970-01-01 UTC when transition starts
        startAdj*: int64  ## Seconds since 1970-01-01, in the transitions timezone,
                          ## when the transition starts
        isDst*: bool      ## If this transition is daylight savings time
        utcOffset*: int32 ## The active offset (west of UTC) for this transition

    InternalTimezone* = object
        transitions*: seq[Transition]
        name*: string

    OlsonVersion* = tuple[year: int32, release: char] # E.g 2014b

    OlsonDatabase* = object
        timezones*: seq[InternalTimezone]
        version*: OlsonVersion

    # Properly parsing the bin format during compile time is to slow
    # due to lack of proper casting. Luckily we can do most of the parsing
    # and simply cast strings to `Transition` during runtime, since it has static size.

    StaticInternalTimezone* = object
        transitions: string
        name*: string

    StaticOlsonDataBase* = object
        timezones*: seq[StaticInternalTimezone]
        version*: OlsonVersion

const Version = 1'i32

# Need this information in VM. Counted manually :-)
proc sizeOf(typ: typedesc[Transition]): int = 21

proc initOlsonDatabase*(year: int32, release: char,
                        zones: seq[InternalTimezone]): OlsonDatabase =
    result.version.year = year
    result.version.release = release
    result.timezones = zones

proc saveToFile*(db: OlsonDatabase, path: string) =
    let fs = newFileStream(path, fmWrite)
    fs.write Version
    fs.write db.version.year
    fs.write db.version.release
    for zone in db.timezones:
        fs.write zone.name.len.int32
        fs.write zone.name
        fs.write zone.transitions.len.int32
        for trans in zone.transitions:
            fs.write trans

proc readFromFile*(path: string): OlsonDatabase =
    let fs = newFileStream(path, fmRead)    
    let version = fs.readInt32
    doAssert version == Version, "Wrong format version"
    let year = fs.readInt32
    let release = fs.readChar
    var zones = newSeq[InternalTimezone]()

    while not fs.atEnd:
        let nameLen = fs.readInt32
        let name = fs.readStr nameLen
        let transitionsLen = fs.readInt32
        var transitions = newSeq[Transition](transitionsLen)

        for i in 0..<transitionsLen:
            var transition: Transition
            discard fs.readData(cast[pointer](addr transition), sizeof(Transition))
            transitions[i] = transition
        zones.add InternalTimezone(
            name: name,
            transitions: transitions
        )
            
    result = initOlsonDatabase(year, release, zones)

# This is a small VM friendly binary parser, probably slow as hell.

{.push compileTime.}

proc castToInt32(str: string): int32 =
    when cpuEndian == littleEndian:
        result = (str[3].int32 shl 24) or
            (str[2].int32 shl 16) or (str[1].int32 shl 8) or str[0].int32
    else:
        result = (str[0].int32 shl 24) or
            (str[1].int32 shl 16) or (str[2].int32 shl 8) or str[3].int32

proc eatI32(str: string, index: var int): int32 =
    result = str[index..(index + 3)].castToInt32
    index.inc 4

proc eatChar(str: string, index: var int): char =
    result = str[index]
    index.inc

proc eatStr(str: string, len: int, index: var int): string =
    result = str[index..(index + len - 1)]
    index.inc len

proc staticReadFromString*(content: string): StaticOlsonDatabase =
    var i = 0
    let version = content.eatI32(i)
    doAssert version == Version, "Wrong format version"    
    result.version.year = content.eatI32(i)
    result.version.release = content.eatChar(i)
    result.timezones = @[]

    while i < content.len:
        let nameLen = content.eatI32(i)
        let name = content.eatStr(nameLen, i)
        let nTransitions = content.eatI32(i)

        result.timezones.add StaticInternalTimezone(
            name: name,
            transitions: content.eatStr(nTransitions * sizeOf(Transition), i)
        )

{.pop.}

# This finishes the parsing during runtime.

proc finalize*(db: StaticOlsonDataBase): OlsonDatabase =
    result.version = db.version
    result.timezones = @[]
    for zone in db.timezones:
        let stream = newStringStream(zone.transitions)
        let transitionsLen = zone.transitions.len div sizeof(Transition)
        var transitions = newSeq[Transition](transitionsLen)

        for i in 0..<transitionsLen:
            var transition: Transition
            discard stream.readData(cast[pointer](addr transition), sizeof(Transition))
            transitions[i] = transition

        result.timezones.add InternalTimezone(
            name: zone.name,
            transitions: transitions
        )