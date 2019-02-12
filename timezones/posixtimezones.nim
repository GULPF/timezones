##[
  The `posixtimezones` module implements handling of the system timezone
  files on posix systems. It's not available on non-posix systems.

  Usage
  -----
  .. code-block :: nim
    import timezones, timezones/posixtimezones
    # Load a timezone from the systems timezone dir
    let zone1 = loadPosixTz("Europe/Stockholm")
    # Load a timezone with an absolute path to the file
    let zone2 = loadPosixTz("/path/to/timezone/file")
    # Load all available timezones from the systems timezone dir
    let db = loadPosixTzDb()
    # Timezones can now be loaded from the db instead of from the file system
    let zone3 = db.tz("Europe/Stockholm")
]##

import std / [times, options, sequtils, os, algorithm, sugar, strutils, tables]
import private / [coordinates, zone1970, timezonedbs]
from .. / timezones import TimezoneInfo

when not defined(posix):
  {.error: "The `posixtimezones` module is only available on posix systems.".}

type
  TTInfo = object
    utcOffset: int32
    isDst: bool
    abbrev: string

  TempTTInfo = object
    tt_gmtoff: int32
    tt_isdst: bool
    tt_abbrind: byte

  TempTransition = object
    timeT: int64
    ttInfo: TTInfo
    ttype: TransitionType

  TransitionType = object
    isStd: bool
    inUtc: bool

  LeapSecond = object
    time: int64  ## The time_t when the leap second occurs.
    total: int32 ## The total number of leap seconds to be applied after
                 ## the corresponding leap second.

  TzFileParsingError* = object of ValueError ## \
      ## Exception which is raised when parsing a posix timezone file fails.

const Zeros15 = @[byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] # 15 zeros

template tzAssert(condition: untyped) =
  if not condition:
    raise newException(TzFileParsingError, "Invalid tz file")

type Readable = int8|int16|int32|int64|byte|bool|char
proc readVal[T: Readable](f: File, _: typedesc[T]): T
    {.raises: [IOError, TzFileParsingError].} =
  # TODO: Investigate if this is the best implementation
  var buffer: array[T.sizeof, byte]
  tzAssert not endOfFile(f)
  tzAssert readBytes(f, buffer, 0, T.sizeof) == T.sizeof
  var conv = buffer
  # The TZ file is in big endian, so in case we're on little endian
  # we must convert it.
  when cpuEndian == littleEndian:
    when T.sizeof == 2:
      conv[0] = buffer[1]
      conv[1] = buffer[0]
    elif T.sizeof == 4:
      conv[0] = buffer[3]
      conv[1] = buffer[2]
      conv[2] = buffer[1]
      conv[3] = buffer[0]
    elif T.sizeof == 8:
      conv[0] = buffer[7]
      conv[1] = buffer[6]
      conv[2] = buffer[5]
      conv[3] = buffer[4]
      conv[4] = buffer[3]
      conv[5] = buffer[2]
      conv[6] = buffer[1]
      conv[7] = buffer[0]
  result = cast[T](conv)

proc readArray(f: File, T: typedesc, len: int): seq[T]
    {.raises: [IOError, TzFileParsingError].} =
  when T.sizeof != 1:
    raise newException(ValueError, "T must have sizeof 1")
  else:
    var buffer = newSeq[byte](len)
    tzAssert not endOfFile(f)
    tzAssert readBytes(f, buffer, 0, len) == len
    result = cast[seq[T]](buffer)

proc readStr(f: File, len: int): string =
  result = cast[string](readArray(f, char, len))

proc readTempTTInfo(f: File): TempTTInfo =
  result.tt_gmtoff = readVal(f, int32)
  result.tt_isdst = readVal(f, bool)
  result.tt_abbrind = readVal(f, byte)

proc extractString(chars: seq[char], start: byte): string =
  # TODO: optimize
  var idx = start
  while idx.int < chars.len and chars[idx] != '\0':
    result.add chars[idx]
    idx.inc

proc loadLocation(dir, tzName: string): Option[(Coordinates, seq[CountryCode])]
                  {.raises: [TzFileParsingError].} =
  let file = dir / "zone1970.tab"
  if not file.fileExists:
    return
  try:
    return extractSingleLocation(file, tzName)
  except ValueError, IOError:
    let e = getCurrentException()
    raise newException(TzFileParsingError, "Failed to parse zone1970.tab", e)

proc loadAllLocations(dir: string):
                      Table[string, (Coordinates, seq[CountryCode])]
                      {.raises: [TzFileParsingError].} =
  let file = dir / "zone1970.tab"
  if not file.fileExists:
    return
  try:
    return extractAllLocations(file)
  except ValueError, IOError:
    let e = getCurrentException()
    raise newException(TzFileParsingError, "Failed to parse zone1970.tab", e)

proc loadTzInternal(dir, path: string,
                    loadLocation = false): TimezoneInternal
                    {.raises: [IOError, TzFileParsingError].} =
  let isGmtZone = path.startsWith("GMT")

  let file = open(dir / path, fmRead)
  defer: close(file)
  tzAssert readStr(file, 4) == "TZif"
  let version = readVal(file, char)
  tzAssert version in {'\0', '2', '3'}
  tzAssert readArray(file, byte, 15) == Zeros15

  # The number of UTC/local indicators stored in the file.
  let tzh_ttisgmtcnt = readVal(file, int32)
  # The number of standard/wall indicators stored in the file.
  let tzh_ttisstdcnt = readVal(file, int32)
  # The number of leap seconds for which data is stored in the file.
  let tzh_leapcnt = readVal(file, int32)
  # The number of "transition times" for which data is stored in the file.
  let tzh_timecnt = readVal(file, int32)
  # The number of "local time types" for which data is stored in the file(must not be zero).
  let tzh_typecnt = readVal(file, int32)
  # The number of characters of "timezone abbreviation strings" stored in the file.
  let tzh_charcnt = readVal(file, int32)

  # time_ts where DST transitions occur.
  var transitionTimeTs = newSeq[int64](tzh_timecnt)
  for idx in 0 ..< tzh_timecnt:
    transitionTimeTs[idx] = readVal(file, int32)

  # Indices into ttinfo structs indicating the changes
  # to be made at the corresponding DST transition.
  var ttInfoIndices = newSeq[byte](tzh_timecnt)
  for idx in 0 ..< tzh_timecnt:
    ttInfoIndices[idx] = readVal(file, byte)

  # ttinfos which give info on DST transitions.
  var tempTTInfos = newSeq[TempTTInfo](tzh_typecnt)
  for idx in 0 ..< tzh_typecnt:
    tempTTInfos[idx] = readTempTTInfo(file)

  # The array of time zone abbreviation characters.
  var tzAbbrevChars = readArray(file, char, tzh_charcnt)

  var leapSeconds = newSeq[LeapSecond](tzh_leapcnt)
  for idx in 0 ..< tzh_leapcnt:
    let time = readVal(file, int32)
    let total = readVal(file, int32)
    leapSeconds[idx] = LeapSecond(time: time, total: total)

  # Indicate whether each corresponding DST transition were specified
  # in standard time or wall clock time.
  var transitionIsStd = newSeq[bool](tzh_ttisstdcnt)
  for idx in 0 ..< tzh_ttisstdcnt:
      transitionIsStd[idx] = readVal(file, bool)

  # Indicate whether each corresponding DST transition associated with
  # local time types are specified in UTC or local time.
  var transitionInUTC = newSeq[bool](tzh_ttisgmtcnt)
  for idx in 0 ..< tzh_ttisgmtcnt:
    transitionInUTC[idx] = readVal(file, bool)

  tzAssert not endOfFile(file)

  if version in {'2', '3'}:
    tzAssert readStr(file, 4) == "TZif"
    tzAssert readVal(file, char) in {'2', '3'}
    tzAssert readArray(file, byte, 15) == Zeros15

    # The number of UTC/local indicators stored in the file.
    let tzh_ttisgmtcnt = readVal(file, int32)
    # The number of standard/wall indicators stored in the file.
    let tzh_ttisstdcnt = readVal(file, int32)
    # The number of leap seconds for which data is stored in the file.
    let tzh_leapcnt = readVal(file, int32)
    # The number of "transition times" for which data is stored in the file.
    let tzh_timecnt = readVal(file, int32)
    # The number of "local time types" for which data is stored in the file(must not be zero).
    let tzh_typecnt = readVal(file, int32)
    # The number of characters of "timezone abbreviation strings" stored in the file.
    let tzh_charcnt = readVal(file, int32)

    # time_ts where DST transitions occur.
    transitionTimeTs = newSeq[int64](tzh_timecnt)
    for idx in 0 ..< tzh_timecnt:
      transitionTimeTs[idx] = readVal(file, int64)

    # Indices into ttinfo structs indicating the changes
    # to be made at the corresponding DST transition.
    ttInfoIndices = newSeq[byte](tzh_timecnt)
    for idx in 0 ..< tzh_timecnt:
      ttInfoIndices[idx] = readVal(file, byte)

    # ttinfos which give info on DST transitions.
    tempTTInfos = newSeq[TempTTInfo](tzh_typecnt)
    for idx in 0 ..< tzh_typecnt:
      tempTTInfos[idx] = readTempTTInfo(file)

    # The array of time zone abbreviation characters.
    tzAbbrevChars = readArray(file, char, tzh_charcnt)

    leapSeconds = newSeq[LeapSecond](tzh_leapcnt)
    for idx in 0 ..< tzh_leapcnt:
      let time = readVal(file, int64)
      let total = readVal(file, int32)
      leapSeconds[idx] = LeapSecond(time: time, total: total)

    # Indicate whether each corresponding DST transition were specified
    # in standard time or wall clock time.
    transitionIsStd = newSeq[bool](tzh_ttisstdcnt)
    for idx in 0 ..< tzh_ttisstdcnt:
        transitionIsStd[idx] = readVal(file, bool)

    # Indicate whether each corresponding DST transition associated with
    # local time types are specified in UTC or local time.
    transitionInUTC = newSeq[bool](tzh_ttisgmtcnt)
    for idx in 0 ..< tzh_ttisgmtcnt:
      transitionInUTC[idx] = readVal(file, bool)

  tzAssert readLine(file).strip() == ""
  # "After  the  second  header and data comes a newline-enclosed,
  #  POSIX-TZ-environment-variable-style string for use in handling
  #  instants after the last transition time stored in the file
  #  (with nothing between the newlines if there is no POSIX representation
  #  for  such  instants)"
  discard readLine(file)
  if not endOfFile(file):
    tzAssert readLine(file).strip() == ""
    tzAssert endOfFile(file)

  var transitionTypes = newSeq[TransitionType](tempTTInfos.len)
  for idx in 0 ..< tempTTInfos.len:
    var isStd = false
    if idx < transitionIsStd.len:
      isStd = transitionIsStd[idx]
    var inUtc = false
    if idx < transitionInUTC.len:
      inUtc = transitionIsStd[idx]
    transitionTypes[idx] = TransitionType(isStd: isStd, inUtc: inUtc)

  var ttInfos = newSeq[TTInfo](tempTTInfos.len)
  for idx in 0 ..< tempTTInfos.len:
    if isGmtZone:
      tempTTInfos[idx].tt_gmtoff *= -1
    let abbrev = extractString(tzAbbrevChars, tempTTInfos[idx].tt_abbrind)
    ttInfos[idx] = TTInfo(
      utcOffset: tempTTInfos[idx].tt_gmtoff,
      isDst: tempTTInfos[idx].tt_isdst,
      abbrev: abbrev)

  var tempTransitions = newSeq[TempTransition](transitionTimeTs.len)
  for idx in 0 ..< transitionTimeTs.len:
      let ttiIndex = ttInfoIndices[idx]
      let transitionTimeT = transitionTimeTs[idx]
      let ttype = transitionTypes[ttiIndex]
      let ttInfo = ttInfos[ttiIndex]

      tempTransitions[idx] = TempTransition(
        timeT: transitionTimeT,
        ttInfo: ttInfo,
        ttype: ttype)

  if tempTransitions.len == 0:
    tzAssert ttInfos.len == 1 and transitionTypes.len == 1
    tempTransitions = @[TempTransition(
      timeT: 0,
      ttInfo: ttInfos[0],
      ttype: transitionTypes[0])]

  tempTransitions.sort((a, b) => a.timeT > b.timeT)
  leapSeconds.sort((a, b) => a.time > b.time)

  var transitions = newSeq[Transition](tempTransitions.len)
  for idx in 0 ..< tempTransitions.len:
    let tempTransition = tempTransitions[idx];
    let transitionTimeT = tempTransition.timeT;
    let ttInfo = tempTransition.ttInfo;

    tzAssert idx == 0 or transitionTimeT > tempTransitions[idx - 1].timeT
    transitions[idx] = Transition(
      startUtc: transitionTimeT,
      startAdj: transitionTimeT + ttInfo.utcOffset,
      isDst: ttInfo.isDst,
      utcOffset: ttInfo.utcOffset
      # abbrev: ttInfo.abbrev
    )

  result.transitions = transitions
  result.name = path

  if loadLocation:
    let opt = loadLocation(dir, path)
    result.location = opt.map(value => value[0])
    result.countries = opt.map(value => value[1]).get(@[])

proc resolvePosixTzPath(path: string): (string, string) =
  if path.isAbsolute:
    result = ("", path)
  else:
    let dir = getEnv("TZDIR", "/usr/share/zoneinfo/")
    result = (dir, path)

proc loadPosixTz*(path: string): Timezone
    {.raises: [IOError, TzFileParsingError].}=
  ## Load a timezone from a posix timezone file.
  ##
  ## If `path` is relative it's interpreted as relative to the system
  ## timezone dir, meaning that e.g `loadPosixTz"Europe/Stockholm"` works.
  ## The timezone dir is `"/usr/share/zoneinfo/"` by default, but can be
  ## overriden by setting the `TZDIR` environment variable.
  let (dir, path) = resolvePosixTzPath(path)
  let tzInternal = loadTzInternal(dir, path)
  result = newTimezone(tzInternal)

proc loadPosixTzInfo*(path: string): TimezoneInfo
    {.raises: [IOError, TzFileParsingError].}=
  ## Load a timezone and related metadata from a posix timezone file.
  ##
  ## The metadata is loaded from the file `zone1970.tab`, which is expected
  ## to exist in the system timezone dir.
  ##
  ## The `path` argument must be a relative path, and will be interpreted as
  ## relative to the system timezone dir.
  ## The timezone dir is `"/usr/share/zoneinfo/"` by default, but can be
  ## overriden by setting the `TZDIR` environment variable.
  doAssert not path.isAbsolute, "`path` must be relative: " & path
  let (dir, path) = resolvePosixTzPath(path)
  let tzInternal = loadTzInternal(dir, path, loadLocation = true)
  result.timezone = newTimezone(tzInternal)
  result.location = tzInternal.location
  result.countries = tzInternal.countries.mapIt($it)

iterator walkDirRecRelative(dir: string): string =
  var stack = @[""]
  while stack.len > 0:
    let d = stack.pop()
    for k, p in walkDir(dir / d, relative = true):
      let rel = d / p
      if k in {pcDir, pcLinkToDir} and k in {pcDir}:
        stack.add rel
      if k in {pcFile}:
        yield rel

proc loadPosixTzDb*(dir = ""):
    timezones.TimezoneDb {.raises: [IOError, TzFileParsingError].} =
  ## Load all available timezones and metadata from ``dir``.
  ##
  ## If `dir` is the empty string, the system timezone dir will be used.
  ##
  ## The version field of the returned ``TimezoneDb`` will be set to the
  ## empty string, because there's no reliable way extract the version from a
  ## timezone dir.
  let dir =
    if dir == "":
      let (dir, _) = resolvePosixTzPath("")
      dir
    else:
      dir
  var zones = newSeq[TimezoneInternal]()
  let locations = loadAllLocations(dir)
  for path in walkDirRecRelative(dir):
    if path.splitFile.ext != "" or path in ["leapseconds", "+VERSION"]:
      continue
    var zone = loadTzInternal(dir, path, loadLocation = false)
    if path in locations:
      let (coords, countries) = locations.getOrDefault(path)
      zone.location = some(coords)
      zone.countries = countries
    zones.add(zone)
  result = timezones.TimezoneDb(initTimezoneDb("", zones))
