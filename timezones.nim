##[
Examples:

.. code-block:: nim
    import times
    import timezones

    let tz = staticTz(hours = -2, minutes = -30)
    echo initDateTime(1, mJan, 2000, 12, 00, 00, tz)
    # => 2000-01-01T12:00:00+02:30

    let stockholm = tz"Europe/Stockholm"
    echo initDateTime(1, mJan, 1850, 00, 00, 00, stockholm)
    # => 1850-01-01T00:00:00+01:12

    let sweden = tzNames("SE")
    echo sweden
    # => @["Europe/Stockholm"]

    let usa = tzNames("US")
    echo usa
    # => @[
    #   "America/New_York",  "America/Adak",      "America/Phoenix",     "America/Yakutat",
    #   "Pacific/Honolulu",  "America/Nome",      "America/Los_Angeles", "America/Detroit",
    #   "America/Chicago",   "America/Boise",     "America/Juneau",      "America/Metlakatla",
    #   "America/Anchorage", "America/Menominee", "America/Sitka",       "America/Denver"
    # ]

    let bangkok = tz"Asia/Bangkok"
    echo bangkok.countries
    # => @["TH", "KH", "LA", "VN"] 
]##

import std / [times, strutils, sequtils, tables, macros, options]
import timezones / private / [timezonefile, sharedtypes]

when not defined(js):
    import std / [os, streams]

export sharedtypes

type
    Country* = string ## A country is represented by
        ## a two character country code, using ISO 3166-1 alpha-2.
        ##
        ## See https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2.

    # Instead of re-exporting timezonefile.TzData we need to do it like this
    # to avoid having the fields of timezonefile.TzData re-exported as well.
    TzDataImpl = distinct timezonefile.TzData
    TzData* = TzDataImpl ## Contains the timezone data
        ## for a specific IANA timezone database version.

# These are templates to avoid taking the perf hit of a function call
# in JS (note that {.inline.} relies on the C compiler).

template tzsByCountry(db: TzData): Table[CountryCode, seq[TimezoneData]] =
    timezonefile.TzData(db).tzsByCountry

template tzByName(db: TzData): Table[string, TimezoneData] =
    timezonefile.TzData(db).tzByName

proc version*(db: TzData): string =
    ## The version of the IANA timezone database being represented by ``db``.
    ## The string consist of the year plus a letter. For example, ``"2018a"``
    ## is the first database release of 2018, ``"2018b"``
    ## the second one and so on.
    timezonefile.TzData(db).version

# type
#     DateTimeClass = enum
#         Unknown, Valid, Invalid, Ambiguous
# # Check C# for naming.
# proc isAmbiguous(tz: Timezone, ndt: NaiveDateTime): bool = discard
# proc isValid(tz: Timezone, ndt: NaiveDateTime): bool = discard
# proc hasDst(tz: Timezone): bool = discard
# proc classify(tz: Timezone, ndt: NaiveDateTIme): DateTimeClass = discard

template binarySeach(transitions: seq[Transition],
                     field: untyped, t: Time): int =

    var lower = 0
    var upper = transitions.high
    while lower < upper:
        var mid = (lower + upper) div 2
        if transitions[mid].field >= t.toUnix:
            upper = mid - 1
        elif lower == mid:
            break
        else:
            lower = mid
    lower

proc initTimezone(tzName: string, tz: TimezoneData): Timezone =
    proc zoneInfoFromAdjTime(adjTime: Time): ZonedTime {.locks: 0.} =
        let index = tz.transitions.binarySeach(startAdj, adjTime)
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

        result.isDst = transition.isDst
        result.utcOffset = -transition.utcOffset
        result.time = adjTime + initDuration(seconds = result.utcOffset)

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
                
    proc zoneInfoFromTime(time: Time): ZonedTime {.locks: 0.} =
        let transition = tz.transitions[tz.transitions.binarySeach(startUtc, time)]
        result.isDst = transition.isDst
        result.utcOffset = -transition.utcOffset
        result.time = time

    result = newTimezone(tzName, zoneInfoFromTime, zoneInfoFromAdjTime)

proc getTz(db: TzData, tzName: string): TimezoneData {.inline.} =
    result = db.tzByName.getOrDefault(tzName)
    if result == nil:
        raise newException(ValueError, "Timezone not found: '$1'" % tzName)

proc countries*(db: TzData, tzName: string): seq[Country] =
    ## Get a list of countries that are known to use ``tzName``.
    ## The result might be empty. Note that some countries use
    ## multiple timezones.
    db.getTz(tzName).countries.mapIt($it)

proc countries*(db: TzData, tz: Timezone): seq[Country] {.inline.} =
    ## Shorthand for ``db.countries(tz.name)``
    db.countries(tz.name)

proc tzNames*(db: TzData, country: Country): seq[string] =
    ## Get a list of timezone names for timezones
    ## known to be used by ``country``.
    let code = cc(country)
    if code in db.tzsByCountry:
        result = db.tzsByCountry[code].mapIt(it.name)
    else:
        result = @[]

proc location*(db: TzData, tzName: string): Option[Coordinates] =
    ## Get the coordinates of a timezone. This is generally the coordinates
    ## of the city in the timezone name.
    ## E.g ``db.location"Europe/Stockholm"`` will give the the coordinates
    ## of Stockholm, the capital of Sweden.
    ##
    ## Note that this is not defined for all timezones in the tzdb database,
    ## so this proc will return an ``none(Coordinates)`` when there is no
    ## coordinates available.
    ## However, if the timezone name is not found, then a ``ValueError`` will
    ## be raised.
    let tz = db.getTz(tzName)
    # `TimezoneData` should probably store `coordinates` as an `Option`,
    # but (0, 0) is in the middle of the ocean so it only matters in principle.
    var default: Coordinates
    if tz.coordinates != default:
        result = some(tz.coordinates)

proc location*(db: TzData, tz: Timezone): Option[Coordinates] {.inline.} =
    ## Shorthand for ``db.location(tz.name)``    
    db.location(tz.name)

proc tz*(db: TzData, tzName: string): Timezone {.inline.} =
    ## Create a timezone using a name from the IANA timezone database.
    result = initTimezone(tzName, db.getTz(tzName))
 
proc parseJsonTimezones*(content: string): TzData =
    ## Parse a timezone database from its JSON representation.
    parseTzData(content).TzData

when not defined(js):
    proc parseJsonTimezones*(s: Stream): TzData =
        ## Parse a timezone database from its JSON representation.
        parseTzData(s).TzData

    proc loadJsonTimezones*(path: string): TzData =
        ## Load a timezone database from a JSON file.
        let fs = openFileStream(path, fmRead)
        defer: fs.close
        parseTzData(fs).TzData

# xxx the silly default path is because it's relative to "timezonefile.nim"
when not defined(nimsuggest):
    when not defined(timezonesPath):
        const timezonesPath = "./2018e.json"
    else:    
        const timezonesPath {.strdefine.} = ""
        # isAbsolute isn't available for JS
        when not defined(js):
            when not timezonesPath.isAbsolute:
                {.error: "Path to custom tz data file must be absolute: " &
                    timezonesPath.}

        {.hint: "Embedding custom tz data file: " & timezonesPath .}

when defined(timezonesPath) and defined(timezonesNoEmbeed):
    {.warning: "Both `timezonesPath` and `timezonesNoEmbeed` was passed".}

when not defined(timezonesNoEmbeed) or defined(nimdoc):
    const content = staticRead timezonesPath

    let embeededTzDataImpl = parseTzData(content).TzData
    let EmbeededTzData* = embeededTzDataImpl ## The embeeded tzdata.
        ## Not available if ``-d:timezonesNoEmbeed`` is used.

    when not defined(nimdoc):
        template EmbeededTzdb*(): TzData
            {.deprecated: "Renamed to EmbeededTzData".} = EmbeededTzData

    {.push inline.}

    proc countries*(tzName: string): seq[Country] =
        ## Convenience proc using the embeeded timezone database.
        runnableExamples:
            doAssert countries"Europe/Stockholm" == @[ "SE" ]
            doAssert countries"Asia/Bangkok" == @[ "TH", "KH", "LA", "VN" ]
        EmbeededTzData.countries(tzName)

    proc countries*(tz: Timezone): seq[Country] =
        ## Convenience proc using the embeeded timezone database.
        EmbeededTzData.countries(tz)

    proc tzNames*(country: Country): seq[string] =
        ## Convenience proc using the embeeded timezone database.
        runnableExamples:
            doAssert "SE".tzNames == @["Europe/Stockholm"]
            doAssert "VN".tzNames == @["Asia/Ho_Chi_Minh", "Asia/Bangkok"]
        EmbeededTzData.tzNames(country)

    proc location*(tzName: string): Option[Coordinates] =
        ## Convenience proc using the embeeded timezone database.
        runnableExamples:
            import options
            doAssert $(location"Europe/Stockholm") == r"Some(59° 20′ 0″ N 18° 3′ 0″ E)"
            # doAssert $(location"Etc/UTC") == "None"
        EmbeededTzData.location(tzName)

    proc location*(tz: Timezone): Option[Coordinates] {.inline.} =
        ## Convenience proc using the embeeded timezone database
        runnableExamples:
            import times
            doAssert utc().location.isNone
        EmbeededTzData.location(tz)

    proc tz*(tzName: string): Timezone =
        ## Convenience proc using the embeeded timezone database.
        runnableExamples:
            import times
            let stockholm = tz"Europe/Stockholm"
            let dt = initDateTime(1, mJan, 1850, 00, 00, 00, stockholm)
            doAssert $dt == "1850-01-01T00:00:00+01:12"
        EmbeededTzData.tz(tzName)

    {.pop.}

proc newTimezone(tzName: string, offset: int): Timezone =
    proc zoneInfoFromAdjTime(adjTime: Time): ZonedTime {.locks: 0.} =
        result.isDst = false
        result.utcOffset = offset
        result.time = adjTime + initDuration(seconds = offset)

    proc zoneInfoFromTime(time: Time): ZonedTime {.locks: 0.}=
        result.isDst = false
        result.utcOffset = offset
        result.time = time

    result = newTimezone(tzName, zoneInfoFromTime, zoneInfoFromAdjTime)

proc staticTz*(hours, minutes, seconds: int = 0): Timezone {.noSideEffect.} =
    ## Create a timezone using a static offset from UTC.
    runnableExamples:
        import times
        let tz = staticTz(hours = -2, minutes = -30)
        doAssert $tz == "STATIC[+02:30:00]" 
        let dt = initDateTime(1, mJan, 2000, 12, 00, 00, tz)
        doAssert $dt == "2000-01-01T12:00:00+02:30"

    let offset = hours * 3600 + minutes * 60 + seconds
    let hours = offset div 3600
    var rem = offset mod 3600
    let minutes = rem div 60
    let seconds = rem mod 60
    
    let offsetStr = abs(hours).intToStr(2) &
        ":" & abs(minutes).intToStr(2) & 
        ":" & abs(seconds).intToStr(2)
    
    let tzName =
        if offset > 0:
            "STATIC[-" & offsetStr & "]"
        else:
            "STATIC[+" & offsetStr & "]"

    result = newTimezone(tzName, offset)

# Trick to simplify doc gen.
# This might break in the future
when defined(nimdoc):
    include timezones/private/sharedtypes