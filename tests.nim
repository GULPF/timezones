import times
import timezones
import unittest

let sweden = tz"Europe/Stockholm"
const f = "yyyy-MM-dd HH:mm zzz"

test "dst edge cases":
    # In case of an impossible time, the time is moved to after the impossible time period
    check initDateTime(26, mMar, 2017, 02, 30, 00, sweden).format(f) == "2017-03-26 03:30 +02:00"
    # In case of an ambiguous time, the earlier time is choosen
    check initDateTime(29, mOct, 2017, 02, 00, 00, sweden).format(f) == "2017-10-29 02:00 +02:00"
    # These are just dates on either side of the dst switch
    check initDateTime(29, mOct, 2017, 01, 00, 00, sweden).format(f) == "2017-10-29 01:00 +02:00"
    check initDateTime(29, mOct, 2017, 01, 00, 00, sweden).isDst
    check initDateTime(29, mOct, 2017, 03, 01, 00, sweden).format(f) == "2017-10-29 03:01 +01:00"
    check (not initDateTime(29, mOct, 2017, 03, 01, 00, sweden).isDst)
    
    check initDateTime(21, mOct, 2017, 01, 00, 00).format(f) == "2017-10-21 01:00 +02:00"

test "from utc":
    var local = fromUnix(1469275200).inZone(sweden)
    var utc = fromUnix(1469275200).utc
    let claimedOffset = initDuration(seconds = local.utcOffset)
    local.utcOffset = 0
    check claimedOffset == utc.toTime - local.toTime

test "staticTz":
    check staticTz(hours = 2).name == "STATIC[-02:00:00]"
    check staticTz(hours = 2, minutes = 1).name == "STATIC[-02:01:00]"    
    check staticTz(hours = 2, minutes = 1, seconds = 13).name == "STATIC[-02:01:13]"
    let tz = staticTz(seconds = 1)
    let dt = initDateTime(1, mJan, 2000, 00, 00, 00, tz)
    check dt.utcOffset == -1