import times
import strutils
import json
import tables

when not defined(JS):
    import os
    import streams

type
    # Casting `string` to `Transition` isn't possible in JS,
    # so for that backend we need to store the transitions as JSON.
    FormatKind* = enum
        fkJson = (0, "JSON"),
        fkBinary = (1, "BINARY")

    Transition* = object {.packed.} # Packed so that it can be read/written directly.
        startUtc*: int64  ## Seconds since 1970-01-01 UTC when transition starts
        startAdj*: int64  ## Seconds since 1970-01-01, in the transitions timezone,
                          ## when the transition starts
        isDst*: bool      ## If this transition is daylight savings time
        utcOffset*: int32 ## The active offset (west of UTC) for this transition

    Dms* = tuple[deg, min, sec: int16]
    Coordinates* = tuple[lat, lon: Dms]

    TimezoneData* = object
        transitions*: seq[Transition]
        name*: string

    OlsonVersion* = tuple[year: int32, release: char] # E.g 2014b

    OlsonDatabase* = object
        timezones*: Table[string, TimezoneData]
        locations*: Table[string, Location]
        version*: OlsonVersion
        startYear*: int32
        endYear*: int32
        fk*: FormatKind

    Location* = object
        name*: string
        ccs*: seq[string]
        position*: Coordinates

    # Properly parsing the bin format during compile time is to slow
    # due to lack of proper casting. Luckily we can do most of the parsing
    # and simply cast strings to `Transition` during runtime, since it has static size.

    StaticTimezoneData* = object
        transitions: string
        name*: string

    StaticOlsonDataBase* = object
        timezones*: seq[StaticTimezoneData]
        locations*: seq[Location]
        version*: OlsonVersion
        startYear*: int32
        endYear*: int32
        fk: FormatKind
        # A collection of all country codes are placed in this
        # field to make it easy to generate an enum.
        ccs*: seq[string]

    # These are the runtime versions of ``StaticTimezoneData`` and ``StaticOlsonDatabase``.
    # `OlsonDatabase` could be reused for this, but
    #   A) Compile time knowledge means that we can use an enum for CountryCode
    #   B) ``OlsonDatabase`` is almost a direct representation of what is stored in the file.
    #      This type on the other hand is optimized for how the data is actually used.

    TimezoneId* = int16

    RuntimeTimezoneData*[ccEnum: enum] = object
        transitions*: seq[Transition]
        position*: Coordinates
        ccs*: set[ccEnum]
        name*: string

    RuntimeOlsonDatabase*[ccEnum: enum, N: static[int]] = object
        timezones*: array[N, RuntimeTimezoneData[ccEnum]]
        idsByCountry*: array[ccEnum, seq[TimezoneId]]
        idByName*: Table[string, TimezoneId]

    # I'd prefer to use exceptions for this, but they are not available
    # at compile time.

    ReadStatus* = enum
        rsSuccess # intentionally the default value
        rsFileDoesNotExist
        rsIncorrectFormatVersion
        rsExpectedJsonFormat

    ReadResult*[T: OlsonDatabase|StaticOlsonDataBase] = tuple
        status: ReadStatus
        payload: T

# The current version of the binary format
const Version = 4'i32
# Header uses 32 bytes.
const HeaderSize = 32'i32
# The header size used by this version.
const CurrentHeaderSize = 17'i32

const HeaderPadding = newString(HeaderSize - CurrentHeaderSize)

template cproc(def: untyped) =
    when not defined(JS):
        def

proc parseOlsonVersion*(versionStr: string): OlsonVersion =
    result.year = versionStr[0..3].parseInt.int32
    result.release = versionStr[4]

proc `$`*(version: OlsonVersion): string =
    $version.year & version.release

proc splitCountryCodes(str: string): seq[string] =
    result = newSeq[string](str.len div 2)
    for i in countup(0, str.high, 2):
        result[i div 2] = str[i] & str[i + 1]

proc initLocation*(name: string, position: Coordinates, ccs: seq[string]): Location =
    result.name = name
    result.position = position
    result.ccs = ccs

proc initOlsonDatabase*(version: OlsonVersion, startYear, endYear: int32,
                        zones: Table[string, TimezoneData],
                        locations: Table[string, Location]): OlsonDatabase =
    result.version = version
    result.startYear = startYear
    result.endYear = endYear
    result.timezones = zones
    result.locations = locations

proc readStr(s: Stream): string {.cproc.} =
    let len = s.readInt32
    result = s.readStr(len)

proc readPosition(s: Stream): Coordinates {.cproc.} =
    result.lat.deg = s.readInt16
    result.lat.min = s.readInt16
    result.lat.sec = s.readInt16
    result.lon.deg = s.readInt16
    result.lon.min = s.readInt16
    result.lon.sec = s.readInt16

proc saveToFile*(db: OlsonDatabase, path: string, fk: FormatKind) {.cproc.} =
    let fs = newFileStream(path, fmWrite)
    defer: fs.close
    fs.write Version
    fs.write db.version.year
    fs.write db.version.release
    fs.write db.startYear
    fs.write db.endYear
    fs.write fk.int32
    fs.write HeaderPadding

    fs.write db.locations.len.int32
    for name, location in db.locations:
        fs.write name.len.int32
        fs.write name
        fs.write location.ccs.len.int32 * 2 # Nbr of bytes, not nbr of ccs
        fs.write location.ccs.join("")
        fs.write location.position

    for name, zone in db.timezones:
        fs.write zone.name.len.int32
        fs.write zone.name
        case fk
        of fkBinary:
            fs.write (zone.transitions.len * sizeOf(Transition)).int32
            for trans in zone.transitions:
                fs.write trans
        of fkJson:
            let json = $(%zone.transitions)
            fs.write json.len.int32
            fs.write json

proc readFromFile*(path: string): ReadResult[OlsonDatabase] {.cproc.} =
    if not path.fileExists:
        result.status = rsFileDoesNotExist
        return

    let fs = newFileStream(path, fmRead)    
    defer: fs.close
    let version = fs.readInt32

    if version != Version:
        result.status = rsIncorrectFormatVersion
        return

    result.payload.version.year = fs.readInt32
    result.payload.version.release = fs.readChar
    result.payload.startYear = fs.readInt32
    result.payload.endYear = fs.readInt32
    result.payload.fk = fs.readInt32().FormatKind
    discard fs.readStr HeaderPadding.len
    result.payload.timezones = initTable[string, TimezoneData]()
    result.payload.locations = initTable[string, Location]()

    for i in 0..<fs.readInt32:
        let name = fs.readStr
        let ccs = fs.readStr.splitCountryCodes
        let pos = fs.readPosition
        result.payload.locations[name] = initLocation(name, pos, ccs)

    while not fs.atEnd:
        let name = fs.readStr
        let transitionsLen = fs.readInt32
        var transitions = newSeq[Transition](transitionsLen)

        case result.payload.fk
        of fkBinary:
            for i in 0..<(transitionsLen div sizeOf(Transition)):
                var transition: Transition
                discard fs.readData(cast[pointer](addr transition), sizeOf(Transition))
                transitions[i] = transition
        of fkJson:
            transitions = parseJson(fs.readStr(transitionsLen)).to(seq[Transition])

        result.payload.timezones[name] = TimezoneData(
            name: name,
            transitions: transitions
        )

# This is a small VM friendly binary parser, probably slow as hell.

{.push compileTime.}
{.push inline.}

proc toI32(str: string): int32 =
    ## xxx this is terrible, it will break when using JS with a file in bigEndian
    when cpuEndian == littleEndian or defined(JS):
        result = (str[3].int32 shl 24) or
            (str[2].int32 shl 16) or (str[1].int32 shl 8) or str[0].int32
    else:
        result = (str[0].int32 shl 24) or
            (str[1].int32 shl 16) or (str[2].int32 shl 8) or str[3].int32

proc toI16(str: string): int16 =
    ## xxx this is terrible, it will break when using JS with a file in bigEndian
    when cpuEndian == littleEndian or defined(JS):
        result = (str[1].int16 shl 8) or str[0].int16
    else:
        result = (str[0].int16 shl 8) or str[1].int16

proc eatI32(str: string, index: var int): int32 =
    result = str[index..(index + 3)].toI32
    index.inc 4

proc eatI16(str: string, index: var int): int16 =
    result = str[index..(index + 1)].toI16
    index.inc 2

proc eatChar(str: string, index: var int): char =
    result = str[index]
    index.inc

proc eatStr(str: string, len: int, index: var int): string =
    # VM complains for large json tzdb files if a slice is used here :/
    result = str.substr(index, index + len - 1)
    index.inc len

proc eatStr(str: string, index: var int): string =
    ## Assumes that the string field is prepended by a len field.
    let len = str.eatI32(index)
    result = str.eatStr(len, index)

proc eatPosition(str: string, index: var int): Coordinates =
    result.lat.deg = str.eatI16(index)
    result.lat.min = str.eatI16(index)
    result.lat.sec = str.eatI16(index)
    result.lon.deg = str.eatI16(index)
    result.lon.min = str.eatI16(index)
    result.lon.sec = str.eatI16(index)

{.pop.} # inline

proc staticReadFromFile*(path: string): ReadResult[StaticOlsonDatabase] =
    # if not path.fileExists:
    #     result.status = rsFileDoesNotExist
    #     return

    let content = staticRead path    
    var i = 0

    if content.eatI32(i) != Version:
        result.status = rsIncorrectFormatVersion
        return

    result.payload.version.year = content.eatI32(i)
    result.payload.version.release = content.eatChar(i)
    result.payload.startYear = content.eatI32(i)
    result.payload.endYear = content.eatI32(i)
    result.payload.fk = content.eatI32(i).FormatKind
    i.inc HeaderPadding.len
    result.payload.timezones = @[]
    result.payload.locations = @[]
    result.payload.ccs = @[]

    if defined(JS) and result.payload.fk != fkJson:
        result.status = rsExpectedJsonFormat
        return

    for _ in 0..<content.eatI32(i):
        let name = content.eatStr(i)
        let ccs = content.eatStr(i).splitCountryCodes
        let pos = content.eatPosition(i)
        result.payload.locations.add initLocation(name, pos, ccs)
        # O(bad)
        for cc in ccs:
            if cc notin result.payload.ccs:
                result.payload.ccs.add cc

    while i < content.len:
        let name = content.eatStr(i)
        let transitions = content.eatStr(i)
        result.payload.timezones.add StaticTimezoneData(
            name: name,
            transitions: transitions
        )

{.pop.} # compileTime

# This finishes the parsing during runtime.

proc parseTransitions(transitions: string,
                      format: FormatKind): seq[Transition] =
    when defined(JS):
        parseJson(transitions).to(seq[Transition])
    else:
        case format
        of fkJson:
            result = parseJson(transitions).to(seq[Transition])
        of fkBinary:
            let stream = newStringStream(transitions)
            defer: stream.close
            let transitionsLen = transitions.len div sizeof(Transition)
            result = newSeq[Transition](transitionsLen)

            for i in 0..<transitionsLen:
                var transition: Transition
                discard stream.readData(cast[pointer](addr transition),
                    sizeof(Transition))
                result[i] = transition

proc finalize*[ccEnum: enum; N: static[int]](db: StaticOlsonDataBase): RuntimeOlsonDatabase[ccEnum, N] =
    when defined(JS):
        assert db.fk == fkJson

    result.idByName = initTable[string, TimezoneId]()

    var tzId: TimezoneId = 0

    for tz in db.timezones:
        result.timezones[tzId] = RuntimeTimezoneData[ccEnum](
            transitions: parseTransitions(tz.transitions, db.fk),
            name: tz.name
        )
        result.idByName[tz.name] = tzId

        tzId.inc

    for loc in db.locations:
        let id = result.idByName[loc.name]
        
        for ccStr in loc.ccs:
            let cc = parseEnum[ccEnum](ccStr)
            if result.idsByCountry[cc].isNil:
                result.idsByCountry[cc] = @[id]
            else:
                result.idsByCountry[cc].add id
            result.timezones[id].ccs.incl cc
        
        result.timezones[id].position = loc.position