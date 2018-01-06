import streams

type
    Transition* = object {.packed.}
        startUtc*: int64  ## Seconds since 1970-01-01 UTC when transition starts
        startAdj*: int64  ## Seconds since 1970-01-01, in the transitions timezone,
                          ## when the transition starts
        isDst*: bool      ## If this transition is daylight savings time
        utcOffset*: int32 ## The active offset (west of UTC) for this transition

    InternalTimezone* = object {.packed.}
        transitions*: seq[Transition]
        name*: string

    OlsonVersion* = tuple[year: int32, release: char] # E.g 2014b

    OlsonDatabase* = object
        timezones*: seq[InternalTimezone]
        version*: OlsonVersion

const Version = 1'i32

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

proc readDb(stream: Stream): OlsonDatabase =
    let version = stream.readInt32
    doAssert version == Version, "Wrong format version"
    let year = stream.readInt32
    let release = stream.readChar
    var zones = newSeq[InternalTimezone]()

    while not stream.atEnd:
        let nameLen = stream.readInt32
        let name = stream.readStr nameLen
        let transitionsLen = stream.readInt32
        var transitions = newSeq[Transition](transitionsLen)

        for i in 0..<transitionsLen:
            var transition: Transition
            discard stream.readData(cast[pointer](addr transition), sizeof(Transition))
            transitions[i] = transition
        zones.add InternalTimezone(
            name: name,
            transitions: transitions
        )
            
    result = initOlsonDatabase(year, release, zones)

proc readFromFile*(path: string): OlsonDatabase =
    let fs = newFileStream(path, fmRead)    
    result = fs.readDb()

proc readFromString*(content: string): OlsonDatabase =
    let ss = newStringStream(content)
    result = ss.readDb()