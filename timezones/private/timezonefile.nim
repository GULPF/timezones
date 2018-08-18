import std / [strutils, sequtils, json, tables, hashes]
import sharedtypes

when not defined(JS):
    import std / [os, streams]

type
    Transition* = object
        startUtc*: int64  ## Seconds since 1970-01-01 UTC when transition starts
        startAdj*: int64  ## Seconds since 1970-01-01, in the transitions timezone,
                          ## when the transition starts
        isDst*: bool      ## If this transition is daylight savings time
        utcOffset*: int32 ## The active offset (west of UTC) for this transition

    TimezoneData* = ref object
        transitions*: seq[Transition]
        coordinates*: Coordinates
        countries*: seq[CountryCode]
        name*: string

    CountryCode* = distinct array[2, char] ## Two character country code,
            ## using ISO 3166-1 alpha-2.
            ## Use ``$`` to get the raw country code.
            ##
            ## See https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2.

    TzData* = object
        tzsByCountry*: Table[CountryCode, seq[TimezoneData]]
        tzByName*: Table[string, TimezoneData]
        version*: string

    JsonTzData* = object ## This is the data structure that is stored
                         ## in the JSON file.
        timezones: seq[TimezoneData]
        version: string

template cproc(def: untyped) =
    when not defined(JS):
        def

proc `==`*(a, b: CountryCode): bool {.borrow.}
    ## Compare two country codes.

proc cc*(str: string): CountryCode =
    ## Create a ``CountryCode`` from its string representation.
    ## Note that ``str`` is not validated except for it's length.
    ## This means that even country codes that (currently) doesn't exist
    ## in ISO 3166-1 alpha-2 (like ``YX``, ``YZ``, etc) are accepted.
    runnableExamples:
        let usa = cc"US"
        doAssert $usa == "US"
    if str.len != 2:
        raise newException(ValueError,
            "Country code must be exactly two characters: " & str)
    if not str[0].isUpperAscii or not str[1].isUpperAscii:
        raise newException(ValueError,
            "Country code must be upper case: " & str)
    let arr = [str[0], str[1]]
    result = arr.CountryCode

proc `$`*(cc: CountryCode): string =
    ## Get the string representation of ``cc``.
    runnableExamples:
        let usa = cc"US"
        doAssert $usa == "US"
    let arr = array[2, char](cc)
    arr[0] & arr[1]

proc `%`(cc: CountryCode): JsonNode =
    %($cc)

proc hash(cc: CountryCode): Hash {.borrow.}

proc `%`(coords: Coordinates): JsonNode = %[
    coords.lat.deg, coords.lat.min, coords.lat.sec,
    coords.lon.deg, coords.lon.min, coords.lon.sec,
]

proc `%`(db: TzData): JsonNode =
    %JsonTzData(
        timezones: toSeq(db.tzByName.values),
        version: db.version
    )

proc initTzData*(version: string, zones: seq[TimezoneData]): TzData =
    result.version = version
    result.tzByName = initTable[string, TimezoneData]()
    result.tzsByCountry = initTable[CountryCode, seq[TimezoneData]]()

    for timezoneData in zones:
        result.tzByName[timezoneData.name] = timezoneData
        for countryCode in timezoneData.countries:
            if countryCode in result.tzsByCountry:
                result.tzsByCountry[countryCode].add timezoneData
            else:
                result.tzsByCountry[countryCode] = @[timezoneData]

# XXX: rename
proc saveToFile*(db: TzData, path: string) {.cproc.} =
    let fs = newFileStream(path, fmWrite)
    defer: fs.close
    fs.write $(%db)

proc deserializeTzData(jnode: JsonNode): TzData =
    # `to` macro can't handle char
    let version = $jnode["version"].getStr
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
    
    result = initTzData(version, zones)

proc parseTzData*(s: string): TzData =
    parseJson(s).deserializeTzData

when not defined(js):
    proc parseTzData*(s: Stream): TzData =
        parseJson(s).deserializeTzData