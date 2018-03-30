import times
import strutils
import tables
import macros
import options
import timezones/private/timezonefile

export timezonefile.Coordinates

proc `$`*(coords: Coordinates): string =
    let latD = if coords.lat.deg < 0: 'S' else: 'N'
    let lonD = if coords.lon.deg < 0: 'W' else: 'E'
    "$1° $2′ $3″ $4 $5° $6′ $7″ $8".format(
        coords.lat.deg, coords.lat.min, coords.lat.sec, latD,
        coords.lon.deg, coords.lon.min, coords.lon.sec, lonD
    )

template nodoc(fun: untyped): untyped =
    when not defined(nimsuggest) and not defined(nimdoc):
        fun

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

proc initTimezone(tzname: string, tz: TimezoneData): Timezone =
    # xxx it might be bad to keep the transitions in the closure,
    # since they're so many.
    # Probably better if the closure keeps a small reference to the index in the
    # shared db.
    proc zoneInfoFromTz(adjTime: Time): ZonedTime {.locks: 0.} =
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
                result.adjTime = fromUnix(adjTime.toUnix + offsetDiff)
                return

        result.isDst = transition.isDst
        result.utcOffset = -transition.utcOffset
        result.adjTime = adjTime

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
                
    proc zoneInfoFromUtc(time: Time): ZonedTime {.locks: 0.} =
        let transition = tz.transitions[tz.transitions.binarySeach(startUtc, time)]
        result.isDst = transition.isDst
        result.utcOffset = -transition.utcOffset
        result.adjTime = fromUnix(time.toUnix + transition.utcOffset)

    result.name = tzname
    result.zoneInfoFromTz = zoneInfoFromTz
    result.zoneInfoFromUtc = zoneInfoFromUtc

proc getId(db: OlsonDatabase, tzname: string): TimezoneId {.inline.} =
    when compiles(db.getOrDefault(tzname, -1)):
        result = db.getOrDefault(tzname, -1)
        if result == -1:
            raise newException(ValueError, "Timezone not found: '$1'" % tzname)
    else:
        if tzname in db.idByName:
            result = db.idByName[tzname]
        else:
            raise newException(ValueError, "Timezone not found: '$1'" % tzname)

proc countries*(db: OlsonDatabase, tzname: string): seq[string] =
    ## Get a list of countries that are known to use ``tzname``.
    ## The result might be empty. Note that some countries use
    ## multiple timezones.
    db.timezones[db.getId(tzname)].countries

proc countries*(db: OlsonDatabase, tz: Timezone): seq[string] {.inline.} =
    ## Shorthand for ``db.countries(tz.name)``
    db.countries(tz.name)

proc tzNames*(db: OlsonDatabase, country: string): seq[string] =
    ## Get a list of timezone names for timezones
    ## known to be used by ``country``.
    let ids = db.idsByCountry[country]
    result = newSeq[string](ids.len)
    for idx, id in ids:
        result[idx] = db.timezones[id].name

proc location*(db: OlsonDatabase, tzname: string): Option[Coordinates] =
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
    let id = db.getId(tzname)
    let tz = db.timezones[id]
    # `TimezoneData` should probably store `coordinates` as an `Option`,
    # but (0, 0) is in the middle of the ocean so it only matters in principle.
    var default: Coordinates
    if tz.coordinates != default:
        result = some(tz.coordinates)

proc location*(db: OlsonDatabase, tz: Timezone): Option[Coordinates] {.inline.} =
    ## Shorthand for ``db.location(tz.name)``    
    db.location(tz.name)

proc tz*(db: OlsonDatabase, tzname: string): Timezone {.inline.} =
    ## Create a timezone using a name from the IANA timezone database.
    let id = db.getId(tzname)
    result = initTimezone(tzname, db.timezones[id])
 
proc parseJsonTimezones*(content: string): OlsonDatabase =
    ## Parse a timezone database from its JSON representation.
    timezonefile.parseOlsonDatabase(content)

when not defined(js):
    proc loadJsonTimezones*(path: string): OlsonDatabase =
        ## Load a timezone database from a JSON file.
        timezonefile.loadOlsonDatabase(path)

# xxx the silly default path is because it's relative to "timezonefile.nim"
when not defined(nimsuggest):
    const timezonesPath {.strdefine.} = "./bundled_tzdb_files/2018c.json"

when defined(timezonesPath) and defined(timezonesNoEmbeed):
    {.warning: "Both `timezonesPath` and `timezonesNoEmbeed` was passed".}

when not defined(timezonesNoEmbeed) or defined(nimdoc):
    const content = staticRead timezonesPath
    let EmbeededTzdb* =
        parseOlsonDatabase(content) ## The embeeded tzdata.
                                    ## Not available if -d:timezonesNoEmbeed is used.

    {.push inline.}

    proc countries*(tzname: string): seq[string] =
        ## Convenience proc using the embeeded timezone database.
        runnableExamples:
            doAssert countries"Europe/Stockholm" == [ "SE" ]
            doAssert countries"Asia/Bangkok" == [ "TH", "KH", "LA", "VN" ]
        EmbeededTzdb.countries(tzname)

    proc countries*(tz: Timezone): seq[string] =
        ## Convenience proc using the embeeded timezone database.
        EmbeededTzdb.countries(tz)

    proc tzNames*(country: string): seq[string] =
        ## Convenience proc using the embeeded timezone database.
        runnableExamples:
            doAssert cc"SE".tznames == @["Europe/Stockholm"]
            doAssert cc"VN".tznames == @["Asia/Bangkok", "Asia/Ho_Chi_Minh"]
        EmbeededTzdb.tzNames(country)

    proc location*(tzname: string): Option[Coordinates] =
        ## Convenience proc using the embeeded timezone database.
        runnableExamples:
            import options
            doAssert $(location"Europe/Stockholm") == r"Some(59° 20′ 0″ N 18° 3′ 0″ E)"
            # doAssert $(location"Etc/UTC") == "None"
        EmbeededTzdb.location(tzname)

    proc location*(tz: Timezone): Option[Coordinates] {.inline.} =
        EmbeededTzdb.location(tz)

    proc tz*(tzname: string): Timezone =
        ## Convenience proc using the embeeded timezone database.
        runnableExamples:
            import times
            let sweden = tz"Europe/Stockholm"
            let dt = initDateTime(1, mJan, 1850, 00, 00, 00, sweden)
            doAssert $dt == "1850-01-01T00:00:00+01:12"
        EmbeededTzdb.tz(tzname)

    {.pop.}

proc initTimezone(tzname: string, offset: int): Timezone =

    proc zoneInfoFromTz(adjTime: Time): ZonedTime {.locks: 0.} =
        result.isDst = false
        result.utcOffset = offset
        result.adjTime = adjTime

    proc zoneInfoFromUtc(time: Time): ZonedTime {.locks: 0.}=
        result.isDst = false
        result.utcOffset = offset
        result.adjTime = fromUnix(time.toUnix - offset)

    result.name = tzname
    result.zoneInfoFromTz = zoneInfoFromTz
    result.zoneInfoFromUtc = zoneInfoFromUtc

proc staticTz*(hours, minutes, seconds: int = 0): Timezone {.noSideEffect.} =
    ## Create a timezone using a static offset from UTC.
    runnableExamples:
        import times
        let tz = staticTz(hours = -2, minutes = -30)
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
    
    let tzname =
        if offset > 0:
            "STATIC[-" & offsetStr & "]"
        else:
            "STATIC[+" & offsetStr & "]"            

    result = initTimezone(tzname, offset)