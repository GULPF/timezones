# Fhis file is mostly a direct translation of PosixTimeZone from phobos,
# the standard library of D.

import std / [strutils, algorithm, sugar, os, times]

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

  Transition = object
    timeT: int64
    ttInfo: TTInfo

  LeapSecond = object
    timeT: int64 ## The time_t when the leap second occurs.
    total: int32 ## The total number of leap seconds to be applied after
                 ## the corresponding leap second.

const Zeros15 = @[byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] # 15 zeros

template tzAssert(condition: untyped) =
  doAssert condition, "Invalid tz file"

# Similiar to countUntil in D
template countUntil(lst: openArray, cond: untyped): int =
  var idx = 0
  while true:
    if idx > lst.high:
      idx = -1
      break
    let it {.inject.} = lst[idx]
    if cond:
      break

    idx.inc
  idx

proc calculateLeapseconds(leapSeconds: seq[LeapSecond], time: Time): int =
  if leapSeconds.len == 0:
    return 0

  let unix = toUnix(time)

  if leapSeconds[0].timeT >= unix:
    return 0

  var idx = 0
  while leapSeconds[idx].timeT < unix:
    idx.inc
    if idx > leapSeconds.high:
      return leapSeconds[^1].total

  let leapSecond = if idx == 0: leapSeconds[0] else: leapSeconds[idx - 1]
  result = leapSecond.total

proc newTimezone(name: string,
                 transitions: seq[Transition],
                 leapSeconds: seq[LeapSecond]): Timezone =

  proc zonedTimeFromTimeImpl(time: Time): ZonedTime =
    result.time = time
    let leapSecs = calculateLeapseconds(leapSeconds, time)
    let unix = toUnix(time)
    let found = countUntil(transitions, unix < it.timeT)

    if found == -1:
      result.utcOffset = -(transitions[^1].ttInfo.utcOffset + leapSecs)
      result.isDst = transitions[^1].ttInfo.isDst
      return

    let transition = if found == 0: transitions[0] else: transitions[found - 1]
    result.utcOffset = -(transition.ttInfo.utcOffset + leapSecs)
    result.isDst = transition.ttInfo.isDst

  proc zonedTimeFromAdjTimeImpl(adjTime: Time): ZonedTime =
    template setResult(ttInfo: TTInfo) =
      result.isDst = ttInfo.isDst
      result.utcOffset = -(ttInfo.utcOffset + leapSecs)
      result.time = initTime(unix + result.utcOffset, adjTime.nanosecond)

    let leapSecs = calculateLeapSeconds(leapSeconds, adjTime)
    let unix = toUnix(adjTime)
    let past = unix - convert(Days, Seconds, 1)
    let future = unix + convert(Days, Seconds, 1)

    let pastFound = countUntil(transitions, past < it.timeT)

    if pastFound == -1:
      setResult(transitions[^1].ttInfo)
      return

    let futureFound = countUntil(transitions[pastFound..^1], future < it.timeT)
    let pastTrans = if pastFound == 0: transitions[0]
                    else: transitions[pastFound - 1]

    if futureFound == 0:
      setResult(pastTrans.ttInfo)
      return

    let futureTrans = if futureFound == -1: transitions[^1]
                      else: transitions[pastFound + futureFound - 1]
    let pastOffset = pastTrans.ttInfo.utcOffset

    let newUnix =
      if pastOffset < futureTrans.ttInfo.utcOffset:
        unix - convert(Hours, Seconds, 1)
      else:
        unix

    let found = countUntil(transitions[pastFound..^1],
      (newUnix - pastOffset) < it.timeT)

    if found == -1:
      setResult(transitions[^1].ttInfo)
      return

    let transition = if found == 0: pastTrans
                     else: transitions[pastFound + found - 1]

    let finalUnix = unix - (transition.ttInfo.utcOffset + leapSecs)
    let finalFound = countUntil(transitions, finalUnix < it.timeT)

    if finalFound == -1:
      setResult(transitions[^1].ttInfo)
      result.time = initTime(finalUnix, adjTime.nanosecond)
      return

    let finalTransition = if finalFound == 0: transitions[0]
                          else: transitions[finalFound - 1]

    setResult(finalTransition.ttInfo)
    result.time = initTime(finalUnix, adjTime.nanosecond)

  result = newTimezone(name, zonedTimeFromTimeImpl, zonedTimeFromAdjTimeImpl)

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

when defined(timezonesTzDatabaseDir):
  const timezonesTzDatabaseDir {.strdefine.} = ""
elif defined(posix):
  const timezonesTzDatabaseDir = "/usr/share/zoneinfo/"
else:
  const timezonesTzDatabaseDir = ""

proc loadTz(path: string): Timezone =
  let fullPath =
      if path.isAbsolute: path
      else: timezonesTzDatabaseDir / path
  let isGmtZone = path.startsWith("GMT")

  let file = open(fullPath, fmRead)
  tzAssert readStr(file, 4) == "TZif"
  let version = readVal[char](file)
  tzAssert version in {'\0', '1', '2'}
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
  let tzAbbrevChars = readArray[char](file, tzh_charcnt)

  var leapSeconds = newSeq[LeapSecond](tzh_leapcnt)
  for idx in 0 ..< tzh_leapcnt:
    let timeT = readVal[int32](file)
    let total = readVal[int32](file)
    leapSeconds[idx] = LeapSecond(timeT: timeT, total: total)

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
    tzAssert readVal[char](file) in {'1', '2'}
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
    let tzAbbrevChars = readArray[char](file, tzh_charcnt)

    leapSeconds = newSeq[LeapSecond](tzh_leapcnt)
    for idx in 0 ..< tzh_leapcnt:
      let timeT = readVal[int64](file)
      let total = readVal[int32](file)
      leapSeconds[idx] = LeapSecond(timeT: timeT, total: total)

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
    leapSeconds.sort((a, b) => a.timeT > b.timeT)

    var transitions = newSeq[Transition](tempTransitions.len)
    for idx in 0 ..< tempTransitions.len:
      let tempTransition = tempTransitions[idx];
      let transitionTimeT = tempTransition.timeT;
      let ttInfo = tempTransition.ttInfo;

      tzAssert idx == 0 or transitionTimeT > tempTransitions[idx - 1].timeT
      transitions[idx] = Transition(
        timeT: transitionTimeT,
        ttInfo: ttInfo)

    var stdName = ""
    var dstName = ""
    var hasDST = false;

    for idx in countdown(transitions.high, 0):
      let transition = transitions[idx]
      let ttInfo = transition.ttInfo

      if ttInfo.isDST:
        if dstName == "":
            dstName = ttInfo.abbrev
        hasDST = true;

      else:
        if stdName == "":
          stdName = ttInfo.abbrev

      if stdName != "" and dstName != "":
          break

    # echo "stdName: ", stdName, " ", "dstName: ", dstName

    result = newTimezone(path, transitions, leapSeconds)

# import os
# let tz = loadTz(paramStr(1))

# echo getTime().local
# echo getTime().inZone(tz)

# echo '-'

# echo initDateTime(25, mMar, 2018, 02, 00, 00, local())
# echo initDateTime(25, mMar, 2018, 02, 00, 00, tz)

# echo initDateTime(25, mMar, 2018, 02, 00, 00, local()).toTime.toUnix
# echo initDateTime(25, mMar, 2018, 02, 00, 00, tz).toTime.toUnix

# echo "-"

# echo initDateTime(25, mMar, 2018, 02, 00, 00, loadTz("Europe/Stockholm"))
# echo initDateTime(25, mMar, 2018, 02, 00, 00, loadTz("right/Europe/Stockholm"))
# echo fromUnix(0).inZone(loadTz("Europe/Stockholm"))
# echo fromUnix(0).inZone(loadTz("right/Europe/Stockholm"))
