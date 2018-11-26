# Fhis file is mostly a direct translation of PosixTimeZone from phobos,
# the standard library of D.

import std / times
import .. / timezones, private / posixtimezones_impl

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

when defined(timezonesTzDatabaseDir):
  const timezonesTzDatabaseDir {.strdefine.} = ""
elif defined(posix):
  const timezonesTzDatabaseDir = "/usr/share/zoneinfo/"
else:
  const timezonesTzDatabaseDir = ""

proc loadTz(path: string, dir = timezonesTzDatabaseDir): Timezone =
  let info = loadTzImpl(path, dir)
  result = newTimezone(path, info.transitions, info.leapSeconds)

proc loadTzInfo(path: string, dir = timezonesTzDatabaseDir): TimezoneInfo =
  let info = loadTzImpl(path, dir, loadLocation = true)
  result.timezone = newTimezone(path, info.transitions, info.leapSeconds)
  result.stdname = info.stdName
  result.dstName = info.dstName
  result.location = info.location
  result.countries = info.countries

echo loadTzInfo("Europe/Stockholm")

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
