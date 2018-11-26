##[
Examples:

.. code-block:: nim
    import times
    import timezones

    # Create a timezone representing a static offset from UTC.
    let zone = tz"+02:30"
    echo initDateTime(1, mJan, 2000, 12, 00, 00, zone)
    # => 2000-01-01T12:00:00+02:30

    # Static offset timezones can also be created with the proc ``staticTz``,
    # which is preferable if the offset is only known at runtime.
    doAsert zone == staticTz(hours = -2, minutes = -30)

    # Create a timezone representing a timezone in the IANA timezone database.
    let stockholm = tz"Europe/Stockholm"
    echo initDateTime(1, mJan, 1850, 00, 00, 00, stockholm)
    # => 1850-01-01T00:00:00+01:12

    # Get a list of timezones used by a country.
    # The country is specified with it's two character country code,
    # see ISO 3166-1 alpha-2.
    let sweden = tzNames("SE")
    echo sweden
    # => @["Europe/Stockholm"]

    # Note that some countries use many different timezones.
    let usa = tzNames("US")
    echo usa
    # => @[
    #   "America/New_York",    "America/Adak",      "America/Phoenix",
    #   "America/Yakutat",     "Pacific/Honolulu",  "America/Nome",
    #   "America/Los_Angeles", "America/Detroit",   "America/Chicago",
    #   "America/Boise",       "America/Juneau",    "America/Metlakatla",
    #   "America/Anchorage",   "America/Menominee", "America/Sitka",
    #   "America/Denver"
    # ]

    # Get a list of countries that are known to use a timezone.
    # Note that some timezones are used by multiple countries.
    let bangkok = tz"Asia/Bangkok"
    echo bangkok.countries
    # => @["TH", "KH", "LA", "VN"]
]##

import std / [times, strutils, sequtils, tables, macros, options]
import timezones / private / [timezonefile, coordinates, tzversion]

when not defined(js):
    import std / [os, streams]

when not defined(nimdoc):
    export coordinates

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

    TimezoneInfo* = object
        timezone*: Timezone
        countries*: seq[Country]
        location*: Option[Coordinates]
        stdName*: string
        dstName*: Option[string]

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

proc initTimezone(tzName: string, tz: TimezoneData): Timezone =
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

    result = newTimezone(tzName, zoneInfoFromTime, zoneInfoFromAdjTime)

proc getTz(db: TzData, tzName: string): Option[TimezoneData] {.inline.} =
    result = option(db.tzByName.getOrDefault(tzName))

proc countries*(db: TzData, tzName: string): seq[Country] =
    ## Get a list of countries that are known to use ``tzName``.
    ## The result might be empty. Note that some countries use
    ## multiple timezones.
    let tz = db.getTz(tzName).get(nil)
    result = if tz.isNil: @[] else: tz.countries.mapIt($it)

proc countries*(db: TzData, tz: Timezone): seq[Country] {.inline.} =
    ## Shorthand for ``db.countries(tz.name)``
    db.countries(tz.name)

proc tzNames*(db: TzData, country: Country): seq[string] =
    ## Get a list of timezone names for timezones
    ## known to be used by ``country``.
    ##
    ## Raises a ``ValueError`` if ``country`` isn't exactly two characters.
    let code = cc(country)
    let zonesData = db.tzsByCountry.getOrDefault(code, newSeq[TimezoneData]())
    result = zonesData.mapIt(it.name)

proc location*(db: TzData, tzName: string): Option[Coordinates] =
    ## Get the coordinates of a timezone. This is generally the coordinates
    ## of the city in the timezone name.
    ## E.g ``db.location"Europe/Stockholm"`` will give the the coordinates
    ## of Stockholm, the capital of Sweden.
    ##
    ## Will return ``none(Coordinates)`` if the timezone either doesn't
    ## exist in the database, or if it doesn't have any coordinates in the
    ## database.
    let tz = db.getTz(tzName).get(nil)
    # `TimezoneData` should probably store `coordinates` as an `Option`,
    # but (0, 0) is in the middle of the ocean so it only matters in principle.
    var default: Coordinates
    if not tz.isNil and tz.coordinates != default:
        result = some(tz.coordinates)

proc location*(db: TzData, tz: Timezone): Option[Coordinates] {.inline.} =
    ## Shorthand for ``db.location(tz.name)``
    db.location(tz.name)

proc newTimezone(tzName: string, offset: int): Timezone =
    proc zoneInfoFromAdjTime(adjTime: Time): ZonedTime {.locks: 0.} =
        result.isDst = false
        result.utcOffset = offset
        result.time = adjTime + initDuration(seconds = offset)

    proc zoneInfoFromTime(time: Time): ZonedTime {.locks: 0.} =
        result.isDst = false
        result.utcOffset = offset
        result.time = time

    result = newTimezone(tzName, zoneInfoFromTime, zoneInfoFromAdjTime)

proc tz*(db: TzData, tzName: string): Timezone {.inline.} =
    ## Create a timezone from a timezone name, where the timezone name is one
    ## of the following:
    ## - The string ``"LOCAL"``, representing the systems local timezone.
    ## - A string of the form ``"±HH:MM:SS"`` or ``"±HH:MM"``, representing a
    #    fixed offset from UTC. Note that the sign will be the opposite when
    ##   compared to ``staticTz``. For example, ``tz"+01:00"`` is the same as
    ##   ``staticTz(hour = -1)``.
    ## - A timezone name from the
    ##   `IANA timezone database <https://www.iana.org/time-zones>`_,
    ##   also listed on
    ##   `wikipedia <https://en.wikipedia.org/wiki/List_of_tz_database_time_zones>`_.
    ##
    ## In case ``tzName`` does not follow any of these formats, or the timezone
    ## name doesn't exist in the database, a ``ValueError`` exception is raised.
    if tzName.len == 0:
        raise newException(ValueError, "Timezone name can't be empty")

    if tzName == "LOCAL":
        result = local()
    elif tzName[0] in {'-', '+'}:
        template error =
            raise newException(ValueError,
                "Invalid static timezone offset: " & tzName)
        template parseTwoDigits(str: string, idx: int): int =
            if str[idx] notin {'0'..'9'} or str[idx + 1] notin {'0'..'9'}:
                echo "err"
                error()
            (str[idx].ord - '0'.ord) * 10 + (str[idx].ord - '0'.ord)

        let sign = if tzName[0] == '-': -1 else: +1
        case tzName.len
        of 6:
            if tzName[3] != ':':
                error()
            let h = parseTwoDigits(tzName, 1)
            let m = parseTwoDigits(tzName, 4)
            let offset = h * 3600 + m * 60
            result = newTimezone(tzName, offset)
        of 9:
            if tzName[3] != ':' or tzName[6] != ':':
                error()
            let h = parseTwoDigits(tzName, 1)
            let m = parseTwoDigits(tzName, 4)
            let s = parseTwoDigits(tzName, 7)
            let offset = h * 3600 + m * 60 + s
            result = newTimezone(tzName, offset)
        else:
            error()
    else:
        let tz = db.getTz(tzName).get(nil)
        if tz.isNil:
            raise newException(ValueError,
                "Timezone does not exist in database: " & tzName)
        result = initTimezone(tzName, tz)

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
        const timezonesPath = "./" & Version & ".json"
    else:
        const timezonesPath {.strdefine.} = ""
        # isAbsolute isn't available for JS
        when not defined(js):
            when not timezonesPath.isAbsolute:
                {.error: "Path to custom tz data file must be absolute: " &
                    timezonesPath.}

        {.hint: "Embedding custom tz data file: " & timezonesPath.}

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
            doAssert countries"Europe/Stockholm" == @["SE"]
            doAssert countries"Asia/Bangkok" == @["TH", "KH", "LA", "VN"]
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
            import times, options
            doAssert $(location"Europe/Stockholm") ==
                    r"Some(59° 20′ 0″ N 18° 3′ 0″ E)"
            doAssert (location"Etc/UTC").isNone
            doAssert utc().location.isNone
        EmbeededTzData.location(tzName)

    proc location*(tz: Timezone): Option[Coordinates] {.inline.} =
        ## Convenience proc using the embeeded timezone database
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

proc staticTz*(hours, minutes, seconds: int = 0): Timezone {.noSideEffect.} =
    ## Create a timezone using a static offset from UTC.
    runnableExamples:
        import times
        let tz = staticTz(hours = -2, minutes = -30)
        doAssert $tz == "+02:30"
        let dt = initDateTime(1, mJan, 2000, 12, 00, 00, tz)
        doAssert $dt == "2000-01-01T12:00:00+02:30"

    let offset = hours * 3600 + minutes * 60 + seconds
    let absOffset = abs(offset)
    let hours = absOffset div 3600
    let rem = absOffset mod 3600
    let minutes = abs(rem div 60)
    let seconds = abs(rem mod 60)

    var offsetStr = abs(hours).intToStr(2) &
        ":" & abs(minutes).intToStr(2)

    var secondsStr = abs(seconds)
    if seconds > 0:
        offsetStr.add ':' & secondsStr.intToStr(2)

    let tzName =
        if offset > 0:
            "-" & offsetStr
        else:
            "+" & offsetStr

    result = newTimezone(tzName, offset)

# Trick to simplify doc gen.
# This might break in the future
when defined(nimdoc):
    include timezones/private/coordinates
