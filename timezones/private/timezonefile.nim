import times, strutils, sequtils, json, tables, hashes
import sharedtypes

when not defined(JS):
    import os
    import streams

type
    Transition* = object
        startUtc*: int64  ## Seconds since 1970-01-01 UTC when transition starts
        startAdj*: int64  ## Seconds since 1970-01-01, in the transitions timezone,
                          ## when the transition starts
        isDst*: bool      ## If this transition is daylight savings time
        utcOffset*: int32 ## The active offset (west of UTC) for this transition

    OlsonVersion* = object # E.g 2014b
        year: int32
        release: char

    TimezoneId* = int16

    TimezoneData* = object
        transitions*: seq[Transition]
        coordinates*: Coordinates
        countries*: seq[CountryCode]
        name*: string

    OlsonDatabase* = object
        timezones*: Table[TimezoneId, TimezoneData]
        idsByCountry*: Table[CountryCode, seq[TimezoneId]]
        idByName*: Table[string, TimezoneId]
        version*: OlsonVersion

    JsonOlsonDatabase* = object ## This is the data structure that is stored
                                ## in the JSON file.
        timezones: seq[TimezoneData]
        version: OlsonVersion

template cproc(def: untyped) =
    when not defined(JS):
        def

proc `%`(cc: CountryCode): JsonNode =
    %($cc)

proc hash(cc: CountryCode): Hash {.borrow.}

proc `%`(c: char): JsonNode =
  ## Generic constructor for JSON data. Creates a new `JString JsonNode`.
  new(result)
  result.kind = JString
  result.str = $c

proc `%`(coords: Coordinates): JsonNode = %[
    coords.lat.deg, coords.lat.min, coords.lat.sec,
    coords.lon.deg, coords.lon.min, coords.lon.sec,
]

proc `%`(db: OlsonDatabase): JsonNode =
    %JsonOlsonDatabase(
        timezones: toSeq(db.timezones.values),
        version: db.version
    )

proc parseOlsonVersion*(versionStr: string): OlsonVersion =
    result.year = versionStr[0..3].parseInt.int32
    result.release = versionStr[4]

proc `$`*(version: OlsonVersion): string =
    $version.year & version.release

proc initOlsonDatabase*(version: OlsonVersion,
                        zones: seq[TimezoneData]):
                        OlsonDatabase =
    result.version = version
    result.idByName = initTable[string, TimezoneId]()
    result.idsByCountry = initTable[CountryCode, seq[TimezoneId]]()
    result.timezones = initTable[TimezoneId, TimezoneData]()

    var tzId = 1.TimezoneId
    for timezoneData in zones:
        result.idByName[timezoneData.name] = tzId
        result.timezones[tzId] = timezoneData

        for countryCode in timezoneData.countries:
            if countryCode in result.idsByCountry:
                result.idsByCountry[countryCode].add tzId
            else:
                result.idsByCountry[countryCode] = @[tzId]
        
        tzId.inc

## XXX: rename
proc saveToFile*(db: OlsonDatabase, path: string) {.cproc.} =
    let fs = newFileStream(path, fmWrite)
    defer: fs.close
    fs.write $(%db)

proc deserializeOlsonDatabase(jnode: JsonNode): OlsonDatabase =
    # `to` macro can't handle char
    let version = parseOlsonVersion($jnode["version"]["year"].getInt &
        jnode["version"]["release"].getStr)

    var zones = newSeq[TimezoneData]()

    zones.add TimezoneData(
        name: "Etc/UTC",
        transitions: @[Transition(
            startUtc: 0,
            startAdj: 0,
            isDst: false,
            utcOffset: 0
        )]
    )

    for tz in jnode["timezones"]:

        var countries = newSeq[CountryCode]()
        for countryStr in tz["countries"].to(seq[string]):
            countries.add cc(countryStr)

        let arr = tz["coordinates"].to(array[6, int16])
        let lat = (arr[0], arr[1], arr[2])
        let lon = (arr[3], arr[4], arr[5])
        let coordinates = (lat, lon)

        zones.add TimezoneData(
            transitions: tz["transitions"].to(seq[Transition]),
            coordinates: coordinates,
            countries: countries,
            name: tz["name"].getStr
        )
    
    result = initOlsonDatabase(version, zones)

proc loadOlsonDatabase*(path: string): OlsonDatabase {.cproc.} =
    let fs = newFileStream(path, fmRead)
    defer: fs.close
    parseJson(fs, path).deserializeOlsonDatabase

proc parseOlsonDatabase*(content: string): OlsonDatabase =
    parseJson(content).deserializeOlsonDatabase
