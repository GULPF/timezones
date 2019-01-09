import std / [strutils, sequtils, json, tables, hashes, macros, options, times]
import coordinates

when not defined(JS):
    import std / [os, streams]

type
    Transition* = object
        startUtc*: int64  ## Seconds since 1970-01-01 UTC when transition starts
        startAdj*: int64  ## Seconds since 1970-01-01, in the transitions timezone,
                          ## when the transition starts
        isDst*: bool      ## If this transition is daylight savings time
        utcOffset*: int32 ## The active offset (west of UTC) for this transition
        # abbrev*: string   ## Abbreviated name for the timezone, e.g CEST or CET

    TimezoneInternal* = object
        transitions*: seq[Transition]
        location*: Option[Coordinates]
        countries*: seq[CountryCode]
        name*: string

    CountryCode* = distinct array[2, char] ## Two character country code,
            ## using ISO 3166-1 alpha-2.
            ## Use ``$`` to get the raw country code.
            ##
            ## See https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2.

    TimezoneDb* = object
        tzByName*: Table[string, TimezoneInternal]
        version*: string

    JsonTzDb = object ## This is the data structure that is stored
                         ## in the JSON file.
        timezones: seq[TimezoneInternal]
        version: string

macro cproc(def: untyped): typed =
    result = quote do:
        when not defined(JS):
            `def`

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
    doAssert str.len == 2,
        "Country code must be exactly two characters: " & str
    doAssert str[0].isUpperAscii and str[1].isUpperAscii:
        "Country code must be upper case: " & str
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

proc `%`(coords: Coordinates): JsonNode =
    %[
        coords.lat.deg, coords.lat.min, coords.lat.sec,
        coords.lon.deg, coords.lon.min, coords.lon.sec,
    ]

proc `%`[T](opt: Option[T]): JsonNode =
    if opt.isNone:
        newJNull()
    else:
        %opt.get

proc `%`(db: TimezoneDb): JsonNode =
    %JsonTzDb(
        timezones: toSeq(db.tzByName.values),
        version: db.version
    )

proc initTimezoneDb*(version: string,
                     zones: seq[TimezoneInternal]): TimezoneDb =
    result.version = version
    result.tzByName = initTable[string, TimezoneInternal]()

    for tzInternal in zones:
        result.tzByName[tzInternal.name] = tzInternal

# XXX: rename
proc saveToFile*(db: TimezoneDb, path: string) {.cproc.} =
    let fs = newFileStream(path, fmWrite)
    defer: fs.close
    fs.write $(%db)

proc deserializeTzData(jnode: JsonNode): TimezoneDb =
    # `to` macro can't handle char
    let version = $jnode["version"].getStr
    var zones = newSeq[TimezoneInternal]()

    for tz in jnode["timezones"]:

        var countries = newSeq[CountryCode]()
        for countryStr in tz["countries"].to(seq[string]):
            countries.add cc(countryStr)

        let arr = tz["location"].to(Option[array[6, int16]])
        let location = arr.map do (arr: array[6, int16]) -> Coordinates:
            let lat = (arr[0], arr[1], arr[2])
            let lon = (arr[3], arr[4], arr[5])
            initCoordinates(lat, lon)

        zones.add TimezoneInternal(
            transitions: tz["transitions"].to(seq[Transition]),
            location: location,
            countries: countries,
            name: tz["name"].getStr
        )
    
    result = initTimezoneDb(version, zones)

proc parseTzData*(s: string): TimezoneDb =
    parseJson(s).deserializeTzData

when not defined(js):
    proc parseTzData*(s: Stream): TimezoneDb =
        parseJson(s).deserializeTzData

template linearSeach(transitions: seq[Transition],
                     field: untyped,
                     t: Time): int =
    let unix = t.toUnix
    var index: int
    if transitions[0].field >= unix:
        index = 0
    elif transitions[^1].field <= unix:
        index = transitions.high
    else:
        index = 1
        while unix >= transitions[index].field:
            index.inc
        index.dec
    index

proc newTimezone*(tz: TimezoneInternal): Timezone =
    proc zoneInfoFromAdjTime(adjTime: Time): ZonedTime {.locks: 0.} =
        let index = tz.transitions.linearSeach(startAdj, adjTime)
        let transition = tz.transitions[index]

        if index < tz.transitions.high:
            let current = tz.transitions[index]
            let next = tz.transitions[index + 1]
            let offsetDiff = next.utcOffset - current.utcOffset
            # This means that we are in the invalid time between two transitions
            if adjTime.toUnix > next.startAdj - offsetDiff:
                result.isDst = next.isDst
                result.utcOffset = -next.utcOffset
                let adjTime = adjTime + initDuration(seconds = offsetDiff)
                result.time = adjTime + initDuration(seconds = result.utcOffset)
                return

        if index != 0:
            let prevTransition = tz.transitions[index - 1]
            let offsetDiff = transition.utcOffset - prevTransition.utcOffset
            let adjUnix = adjTime.toUnix

            if offsetDiff < 0:
                # Times in this interval are ambiguous
                # Resolved by picking earlier transition
                if transition.startAdj <= adjUnix and
                        adjUnix < transition.startAdj - offsetDiff:
                    result.isDst = prevTransition.isDst
                    result.utcOffset = -prevTransition.utcOffset
                    result.time = adjTime +
                        initDuration(seconds = result.utcOffset)
                    return

        result.isDst = transition.isDst
        result.utcOffset = -transition.utcOffset
        result.time = adjTime + initDuration(seconds = result.utcOffset)

    proc zoneInfoFromTime(time: Time): ZonedTime {.locks: 0.} =
        let index = tz.transitions.linearSeach(startUtc, time)
        let transition = tz.transitions[index]
        result.isDst = transition.isDst
        result.utcOffset = -transition.utcOffset
        result.time = time

    result = newTimezone(tz.name, zoneInfoFromTime, zoneInfoFromAdjTime)