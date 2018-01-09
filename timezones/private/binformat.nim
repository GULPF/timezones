import streams
import times
import strutils
import os
import json

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
        startYear*: int32
        endYear*: int32
        fk*: FormatKind

    # Casting `string` to `Transition` isn't possible in JS,
    # so for that backend we need to store the transitions as JSON.
    FormatKind* = enum
        fkJson = (0, "JSON"),
        fkBinary = (1, "BINARY")

    # Properly parsing the bin format during compile time is to slow
    # due to lack of proper casting. Luckily we can do most of the parsing
    # and simply cast strings to `Transition` during runtime, since it has static size.

    StaticInternalTimezone* = object
        transitions: string
        name*: string

    StaticOlsonDataBase* = object
        timezones*: seq[StaticInternalTimezone]
        version*: OlsonVersion
        startYear*: int32
        endYear*: int32
        fk: FormatKind

    # I'd prefer to use exceptions for this, but they are not available
    # at compile time.

    ReadStatus* = enum
        rsSuccess # intentionally the default value
        rsFileDoesNotExist
        rsIncorrectFormatVersion

    ReadResult*[T: OlsonDatabase|StaticOlsonDataBase] = tuple
        status: ReadStatus
        payload: T

# The current version of the binary format
const Version = 3'i32
# Header uses 32 bytes.
const HeaderSize = 32'i32
# The header size used by this version.
const CurrentHeaderSize = 17'i32

const HeaderPadding = newString(HeaderSize - CurrentHeaderSize)

# Need this information in VM. Counted manually :-)
# proc sizeOf(typ: typedesc[Transition]): int = 21

proc parseOlsonVersion*(versionStr: string): OlsonVersion =
    result.year = versionStr[0..3].parseInt.int32
    result.release = versionStr[4]

proc `$`*(version: OlsonVersion): string =
    $version.year & version.release

proc initOlsonDatabase*(version: OlsonVersion, startYear, endYear: int32,
                        zones: seq[InternalTimezone]): OlsonDatabase =
    result.version = version
    result.startYear = startYear
    result.endYear = endYear
    result.timezones = zones

proc saveToFile*(db: OlsonDatabase, path: string, fk: FormatKind) =
    let fs = newFileStream(path, fmWrite)
    defer: fs.close
    fs.write Version
    fs.write db.version.year
    fs.write db.version.release
    fs.write db.startYear
    fs.write db.endYear
    fs.write fk.int32
    fs.write HeaderPadding
    for zone in db.timezones:
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

proc readFromFile*(path: string): ReadResult[OlsonDatabase] =
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
    result.payload.timezones = newSeq[InternalTimezone]()

    while not fs.atEnd:
        let nameLen = fs.readInt32
        let name = fs.readStr nameLen
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

        result.payload.timezones.add InternalTimezone(
            name: name,
            transitions: transitions
        )

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

    while i < content.len:
        let nameLen = content.eatI32(i)
        let name = content.eatStr(nameLen, i)
        let transitionsSize = content.eatI32(i)
        result.payload.timezones.add StaticInternalTimezone(
            name: name,
            transitions: content.eatStr(transitionsSize, i)
        )

{.pop.}

# This finishes the parsing during runtime.

proc finalize*(db: StaticOlsonDataBase): OlsonDatabase =
    result.version = db.version
    result.timezones = @[]

    case db.fk
    of fkBinary:
        for zone in db.timezones:
            let stream = newStringStream(zone.transitions)
            defer: stream.close
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
    of fkJson:
        for zone in db.timezones:
            result.timezones.add InternalTimezone(
                name: zone.name,
                transitions: parseJson(zone.transitions).to(seq[Transition])
            )