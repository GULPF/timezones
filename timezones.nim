##[
    .. code-block :: nim
        import times
        import timezones

        # Create a timezone representing a static offset from UTC.
        let zone = tz"+02:30"
        echo initDateTime(1, mJan, 2000, 12, 00, 00, zone)
        # => 2000-01-01T12:00:00+02:30

        # Static offset timezones can also be created with the proc ``staticTz``,
        # which is preferable if the offset is only known at runtime.
        doAssert zone == staticTz(hours = -2, minutes = -30)

        # Create a timezone representing a timezone in the IANA timezone database.
        let stockholm = tz"Europe/Stockholm"
        echo initDateTime(1, mJan, 1850, 00, 00, 00, stockholm)
        # => 1850-01-01T00:00:00+01:12

        # Like above, but returns a `TimezoneInfo` object which contains some
        # extra metadata.
        let stockholmInfo = tzInfo"Europe/Stockholm"
        # Countries are specified with it's two character country code,
        # see ISO 3166-1 alpha-2.
        doAssert stockholmInfo.countries == @["SE"]
        doAssert stockholmInfo.timezone == stockholm

        # Note that some timezones are used by multiple countries.
        let bangkok = tzInfo"Asia/Bangkok"
        doAssert bangkok.countries == @["TH", "KH", "LA", "VN"]
]##


#TODO:
#[
 - Add a binary format for TzData.
]#

import std / [times, strutils, sequtils, tables, macros, options]
import timezones / private / [timezonedbs, coordinates]

when not defined(js):
    import std / [streams]

when not defined(nimdoc):
    export coordinates

when defined(timezonesPath) and defined(timezonesNoEmbeed):
    {.warning: "Both `timezonesPath` and `timezonesNoEmbeed` was passed".}

type
    Country* = string ## \
        ## A country is represented by a two character country code,
        ## using ISO 3166-1 alpha-2.
        ##
        ## See https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2.

    # Instead of re-exporting timezonedbs.TzData we need to do it like this
    # to avoid having the fields of timezonedbs.TzData re-exported as well.
    TimezoneDbImpl = distinct timezonedbs.TimezoneDb
    TimezoneDb* = TimezoneDbImpl ## \
        ## A collection of loaded timezones, typically from a specific release
        ## of the IANA timezone database.

    TimezoneInfo* = object ## \
        ## A timezone with additional metadata attached.
        timezone*: Timezone ## \
            ## The timezone as a ``times.Timezone`` object.
        countries*: seq[Country] ## \
            ## Get a list of countries that are
            ## known to use this timezone.
            ## Note that some countries use
            ## multiple timezones.
        location*: Option[Coordinates]  ## \
            ## Get the coordinates of a timezone. This is generally the
            ## coordinates of the city in the timezone name.
            ## E.g ``db.location"Europe/Stockholm"`` will give the the
            ## coordinates of Stockholm, the capital of Sweden.

var defaultTzDb {.threadvar.}: TimezoneDb
# track if defaultTzDb is loaded (in the current thread)
var defaultTzDbLoaded {.threadvar.}: bool

when not defined(nimsuggest):
    when not defined(timezonesPath):
        from timezones / private / tzversion import TzDbVersion
        const timezonesPath = "./" & TzDbVersion & ".json"
    else:
        const timezonesPath {.strdefine.} = ""
        when not defined(js):
            from os import isAbsolute
            when not timezonesPath.isAbsolute:
                {.error: "Path to custom tz data file must be absolute: '" &
                    timezonesPath & "'".}
        {.hint: "Embedding custom tz data file: " & timezonesPath.}

when not defined(timezonesNoEmbeed) or defined(nimdoc):
    const content = staticRead timezonesPath
    defaultTzDb = parseTzData(content).TimezoneDb
    defaultTzDbLoaded = true

proc parseTzDb*(content: string): TimezoneDb =
    ## Parse a timezone database from its JSON representation.
    parseTzData(content).TimezoneDb

when not defined(js):
    proc parseTzDb*(s: Stream): TimezoneDb =
        ## Parse a timezone database from its JSON representation.
        parseTzData(s).TimezoneDb

    proc loadTzDb*(path: string): TimezoneDb =
        ## Load a timezone database from a JSON file.
        let fs = openFileStream(path, fmRead)
        defer: fs.close()
        parseTzData(fs).TimezoneDb

proc getTz(db: TimezoneDb, tzName: string): (bool, TimezoneInternal)
        {.inline, raises: [].} =
    let tz = timezonedbs.TimezoneDb(db).tzByName.getOrDefault(tzName)
    if tz.name != "":
        result = (true, tz)

proc newTimezone(tzName: string, offset: int): Timezone {.raises: [].} =
    proc zoneInfoFromAdjTime(adjTime: Time): ZonedTime {.locks: 0.} =
        result.isDst = false
        result.utcOffset = offset
        result.time = adjTime + initDuration(seconds = offset)

    proc zoneInfoFromTime(time: Time): ZonedTime {.locks: 0.} =
        result.isDst = false
        result.utcOffset = offset
        result.time = time

    result = newTimezone(tzName, zoneInfoFromTime, zoneInfoFromAdjTime)

proc tz*(db: TimezoneDb, tzName: string): Timezone {.raises: [ValueError].} =
    ## Retrieve a timezone from a timezone name, where the timezone name is one
    ## of the following:
    ## - The string ``"LOCAL"``, representing the systems local timezone.
    ## - A string of the form ``"±HH:MM:SS"`` or ``"±HH:MM"``, representing a
    ##   fixed offset from UTC. Note that the sign will be the opposite when
    ##   compared to ``staticTz``. For example, ``tz"+01:00"`` is the same as
    ##   ``staticTz(hour = -1)``.
    ## - A timezone name from the
    ##   `IANA timezone database <https://www.iana.org/time-zones>`_.
    ##   See
    ##   `wikipedia
    ##   <https://en.wikipedia.org/wiki/List_of_tz_database_time_zones>`_
    ##   for a list of available timezone names. Note that there is no guranteas
    ##   about what timezones are available in ``db``, but as a special rule
    ##   ``"Etc/UTC"`` is always supported.
    ##
    ## In case ``tzName`` does not follow any of these formats, or the timezone
    ## name doesn't exist in the database, a ``ValueError`` is raised.
    if tzName.len == 0:
        raise newException(ValueError, "Timezone name can't be empty")
    if tzName == "LOCAL":
        result = local()
    elif tzName == "Etc/UTC":
        result = utc()
    elif tzName[0] in {'-', '+'}:
        template error =
            raise newException(ValueError,
                "Invalid static timezone offset: " & tzName)
        template parseTwoDigits(str: string, idx: int): int =
            if str[idx] notin {'0'..'9'} or str[idx + 1] notin {'0'..'9'}:
                error()
            (str[idx].ord - '0'.ord) * 10 + (str[idx + 1].ord - '0'.ord)

        let sign = if tzName[0] == '-': 1 else: -1
        case tzName.len
        of 6:
            if tzName[3] != ':':
                error()
            let h = parseTwoDigits(tzName, 1)
            let m = parseTwoDigits(tzName, 4)
            let offset = h * 3600 + m * 60
            result = newTimezone(tzName, sign * offset)
        of 9:
            if tzName[3] != ':' or tzName[6] != ':':
                error()
            let h = parseTwoDigits(tzName, 1)
            let m = parseTwoDigits(tzName, 4)
            let s = parseTwoDigits(tzName, 7)
            let offset = h * 3600 + m * 60 + s
            result = newTimezone(tzName, sign * offset)
        else:
            error()
    else:
        let (exists, tz) = db.getTz(tzName)
        if not exists:
            raise newException(ValueError,
                "Timezone does not exist in database: " & tzName)
        result = newTimezone(tz)

proc setDefaultTzDb*(db: TimezoneDb) =
    ## Sets the timezone database that will be used for ``tz(tzName)`` and
    ## ``tzInfo(tzName)``. The default timezone database is stored in a thread
    ## local variable, so calling this only affects the calling thread!
    defaultTzDb = db

proc getDefaultTzDb*(): TimezoneDb =
    ## Gets the timezone database that is used for ``tz(tzName)`` and
    ## ``tzInfo(tzName)``. The default timezone database is stored in a thread
    ## local varaible, so calling ``setDefaultTzDb`` only affects the calling
    ## thread!
    when not defined(timezonesNoEmbeed) or defined(nimdoc):
        try:
            if not defaultTzDbLoaded:
                # thread-level initialization. static content is still used
                setDefaultTzDb(parseTzDb(content))
                defaultTzDbLoaded = true
        except Exception:
            raise newException(ValueError, "can not find local tz db")
    defaultTzDb

proc tz*(tzName: string): Timezone {.inline, raises: [ValueError].} =
    ## Convenience proc using the default timezone database.
    runnableExamples:
        import times
        let stockholm = tz"Europe/Stockholm"
        let dt = initDateTime(1, mJan, 1850, 00, 00, 00, stockholm)
        doAssert $dt == "1850-01-01T00:00:00+01:12"
    getDefaultTzDb().tz(tzName)

proc tzInfo*(db: TimezoneDb, tzName: string): TimezoneInfo
             {.raises: [ValueError].}=
    ## Retrieve a timezone with additional metadata.
    ##
    ## The ``tzName`` parameter follows the same format as ``db.tz(...)``.
    ##
    ## In case ``tzName`` has an invalid format, or the timezone name doesn't
    ## exist in the database, a ``ValueError`` is raised.
    if tzName.len == 0:
        raise newException(ValueError, "Timezone name can't be empty")

    if tzName == "LOCAL":
        result.timezone = local()
    elif tzName == "Etc/UTC":
        result.timezone = utc()
    elif tzName[0] in {'-', '+'}:
        result.timezone = db.tz(tzname)
    else:
        let (exists, tz) = db.getTz(tzName)
        if not exists:
            raise newException(ValueError,
                "Timezone does not exist in database: " & tzName)
        result.timezone = newTimezone(tz)
        result.countries = tz.countries.mapIt($it)
        result.location = tz.location

proc tzInfo*(tzName: string): TimezoneInfo {.inline, raises: [ValueError].} =
    ## Convenience proc using the default timezone database.
    runnableExamples:
        import times, options
        let stockholmInfo = tzInfo"Europe/Stockholm"
        doAssert stockholmInfo.timezone == tz"Europe/Stockholm"
        doAssert stockholmInfo.countries == @["SE"]
        doAssert $stockholmInfo.location == "Some(59° 20′ 0″ N 18° 3′ 0″ E)"
    getdefaultTzDb().tzInfo(tzName)

proc staticTz*(hours, minutes, seconds: int = 0): Timezone
               {.noSideEffect, raises: [].} =
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

proc version*(db: TimezoneDb): string {.raises: [].} =
    ## The version of the IANA timezone database being represented by ``db``.
    ## The string consist of the year plus a letter. For example, ``"2018a"``
    ## is the first database release of 2018, ``"2018b"``
    ## the second one and so on.
    ##
    ## If the version is unknown, returns `""`.
    timezonedbs.TimezoneDb(db).version

proc tzNames*(db: TimezoneDb): seq[string] {.raises: [].} =
    ## Retrieve a list of all available timezones in ``db``.
    toSeq(timezonedbs.TimezoneDb(db).tzByName.keys)

# Trick to simplify doc gen.
# This might break in the future
when defined(nimdoc):
    include timezones/private/coordinates
