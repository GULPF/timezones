# Fhis file is mostly a direct translation of PosixTimeZone from phobos,
# the standard library of D.

import std / [times, options, sequtils, os, algorithm, sugar, strutils]
import private / [coordinates, zone1970, timezonedbs]
from .. / timezones import TimezoneInfo

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

  TzFileParsingError* = object of ValueError

const Zeros15 = @[byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] # 15 zeros

template tzAssert(condition: untyped) =
  if not condition:
    raise newException(TzFileParsingError, "Invalid tz file")

proc readVal[T: int8|int16|int32|int64|byte|bool|char](f: File): T =
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

proc readArray[T](f: File, len: int): seq[T] =
  when T.sizeof != 1:
    raise newException(ValueError, "T must have sizeof 1")
  else:
    var buffer = newSeq[byte](len)
    tzAssert not endOfFile(f)
    tzAssert readBytes(f, buffer, 0, len) == len
    result = cast[seq[T]](buffer)

proc readStr(f: File, len: int): string =
  result = cast[string](readArray[char](f, len))

proc readTempTTInfo(f: File): TempTTInfo =
  result.tt_gmtoff = readVal[int32](f)
  result.tt_isdst = readVal[bool](f)
  result.tt_abbrind = readVal[byte](f)

proc extractString(chars: seq[char], start: byte): string =
  # TODO: optimize
  var idx = start
  while idx.int < chars.len and chars[idx] != '\0':
    result.add chars[idx]
    idx.inc

proc loadLocation(tzPath: string, dir: string):
    Option[(Coordinates, seq[string])] {.raises: [TzFileParsingError].} =
  let tab = dir / "zone1970.tab"
  if not tab.fileExists:
    return
  try:
    for countries, coords, tzName in zone1970Entries(tab, find = tzPath):
      return some((coords, countries))
  except Exception as e:
    raise newException(TzFileParsingError,
      "Failed to parse zone1970.tab", e)

proc loadTzInternal(path, dir: string,
                    loadLocation = false): TimezoneInternal
                    {.raises: [IOError, TzFileParsingError].} =
  let fullPath =
      if path.isAbsolute: path
      else: dir / path
  let isGmtZone = path.startsWith("GMT")

  let file = open(fullPath, fmRead)
  tzAssert readStr(file, 4) == "TZif"
  let version = readVal[char](file)
  tzAssert version in {'\0', '2', '3'}
  tzAssert readArray[byte](file, 15) == Zeros15

  # The number of UTC/local indicators stored in the file.
  let tzh_ttisgmtcnt = readVal[int32](file)
  # The number of standard/wall indicators stored in the file.
  let tzh_ttisstdcnt = readVal[int32](file)
  # The number of leap seconds for which data is stored in the file.
  let tzh_leapcnt = readVal[int32](file)
  # The number of "transition times" for which data is stored in the file.
  let tzh_timecnt = readVal[int32](file)
  # The number of "local time types" for which data is stored in the file(must not be zero).
  let tzh_typecnt = readVal[int32](file)
  # The number of characters of "timezone abbreviation strings" stored in the file.
  let tzh_charcnt = readVal[int32](file)

  # time_ts where DST transitions occur.
  var transitionTimeTs = newSeq[int64](tzh_timecnt)
  for idx in 0 ..< tzh_timecnt:
    transitionTimeTs[idx] = readVal[int32](file)

  # Indices into ttinfo structs indicating the changes
  # to be made at the corresponding DST transition.
  var ttInfoIndices = newSeq[byte](tzh_timecnt)
  for idx in 0 ..< tzh_timecnt:
    ttInfoIndices[idx] = readVal[byte](file)

  # ttinfos which give info on DST transitions.
  var tempTTInfos = newSeq[TempTTInfo](tzh_typecnt)
  for idx in 0 ..< tzh_typecnt:
    tempTTInfos[idx] = readTempTTInfo(file)

  # The array of time zone abbreviation characters.
  var tzAbbrevChars = readArray[char](file, tzh_charcnt)

  var leapSeconds = newSeq[LeapSecond](tzh_leapcnt)
  for idx in 0 ..< tzh_leapcnt:
    let time = readVal[int32](file)
    let total = readVal[int32](file)
    leapSeconds[idx] = LeapSecond(time: time, total: total)

  # Indicate whether each corresponding DST transition were specified
  # in standard time or wall clock time.
  var transitionIsStd = newSeq[bool](tzh_ttisstdcnt)
  for idx in 0 ..< tzh_ttisstdcnt:
      transitionIsStd[idx] = readVal[bool](file)

  # Indicate whether each corresponding DST transition associated with
  # local time types are specified in UTC or local time.
  var transitionInUTC = newSeq[bool](tzh_ttisgmtcnt)
  for idx in 0 ..< tzh_ttisgmtcnt:
    transitionInUTC[idx] = readVal[bool](file)

  tzAssert not endOfFile(file)

  if version in {'2', '3'}:
    tzAssert readStr(file, 4) == "TZif"
    tzAssert readVal[char](file) in {'2', '3'}
    tzAssert readArray[byte](file, 15) == Zeros15

    # The number of UTC/local indicators stored in the file.
    let tzh_ttisgmtcnt = readVal[int32](file)
    # The number of standard/wall indicators stored in the file.
    let tzh_ttisstdcnt = readVal[int32](file)
    # The number of leap seconds for which data is stored in the file.
    let tzh_leapcnt = readVal[int32](file)
    # The number of "transition times" for which data is stored in the file.
    let tzh_timecnt = readVal[int32](file)
    # The number of "local time types" for which data is stored in the file(must not be zero).
    let tzh_typecnt = readVal[int32](file)
    # The number of characters of "timezone abbreviation strings" stored in the file.
    let tzh_charcnt = readVal[int32](file)

    # time_ts where DST transitions occur.
    transitionTimeTs = newSeq[int64](tzh_timecnt)
    for idx in 0 ..< tzh_timecnt:
      transitionTimeTs[idx] = readVal[int64](file)

    # Indices into ttinfo structs indicating the changes
    # to be made at the corresponding DST transition.
    ttInfoIndices = newSeq[byte](tzh_timecnt)
    for idx in 0 ..< tzh_timecnt:
      ttInfoIndices[idx] = readVal[byte](file)

    # ttinfos which give info on DST transitions.
    tempTTInfos = newSeq[TempTTInfo](tzh_typecnt)
    for idx in 0 ..< tzh_typecnt:
      tempTTInfos[idx] = readTempTTInfo(file)

    # The array of time zone abbreviation characters.
    tzAbbrevChars = readArray[char](file, tzh_charcnt)

    leapSeconds = newSeq[LeapSecond](tzh_leapcnt)
    for idx in 0 ..< tzh_leapcnt:
      let time = readVal[int64](file)
      let total = readVal[int32](file)
      leapSeconds[idx] = LeapSecond(time: time, total: total)

    # Indicate whether each corresponding DST transition were specified
    # in standard time or wall clock time.
    transitionIsStd = newSeq[bool](tzh_ttisstdcnt)
    for idx in 0 ..< tzh_ttisstdcnt:
        transitionIsStd[idx] = readVal[bool](file)

    # Indicate whether each corresponding DST transition associated with
    # local time types are specified in UTC or local time.
    transitionInUTC = newSeq[bool](tzh_ttisgmtcnt)
    for idx in 0 ..< tzh_ttisgmtcnt:
      transitionInUTC[idx] = readVal[bool](file)

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
    let opt = loadLocation(path, dir)
    result.location = opt.map(value => value[0])
    result.countries =
      opt.map(value => value[1]).get(@[])
        .filterIt(it.len == 2) # Wrong country codes are silently ignored
        .mapIt(cc(it))

when defined(nimdoc):
  # TODO: Should I respect TZDIR env variable?
  const PosixTimezonesDir* = "" ## Doc comment here
elif defined(PosixTimezonesDir):
  const PosixTimezonesDir* {.strdefine.} = ""
elif defined(posix):
  const PosixTimezonesDir* = "/usr/share/zoneinfo/"
else:
  const PosixTimezonesDir* = ""

proc loadTz*(path: string, dir = PosixTimezonesDir): Timezone =
  ## Load a timezone from a posix timezone file.
  ##
  ## If ``path`` is a relative path, it's treated as relative to ``dir``.
  ## The timezone will use ``path`` as name (typically this will result
  ## in the name matching the IANA timezone name).
  let tzInternal = loadTzInternal(path, dir)
  result = newTimezone(tzInternal)

proc loadTzInfo*(path: string, dir = PosixTimezonesDir): TimezoneInfo =
  ## Load a timezone and related metadata from a posix timezone file.
  ##
  ## The metadata is loaded from the file ``zone1970.tab``, which is expected
  ## to exists in ``dir`` (this will be true on a typicall posix system).
  ##
  ## If ``path`` is a relative path, it's treated as relative to ``dir``.
  ## The timezone will use ``path`` as name (typically this will result
  ## in the name matching the IANA timezone name).
  let tzInternal = loadTzInternal(path, dir, loadLocation = true)
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

proc loadTzDb*(filter: seq[string],
               dir = PosixTimezonesDir): timezones.TimezoneDb =
  ## Load all available timezones from ``dir``.
  var zones = newSeq[TimezoneInternal]()
  for tzName in walkDirRecRelative(dir):
    if tzName.splitFile.ext != "" or tzName in ["leapseconds", "+VERSION"]:
      continue
    if filter.len > 0 and tzname notin filter:
      continue
    # TODO: Don't use loadLocation here!
    zones.add(loadTzInternal(tzname, dir, loadLocation = true))
  result = timezones.TimezoneDb(initTimezoneDb("", zones))
