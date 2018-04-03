# This file contains some data types and procs that are needed by
# ``timezonefile`` but also need to be exported by the end user.
# This seperation is done so that ``include`` can be abused for doc gen.

import strutils

type

    Dms* = tuple[deg, min, sec: int16] ## A coordinate specified
            ## in degrees (deg), minutes (min) and seconds (sec).
    Coordinates* = tuple[lat, lon: Dms] ## Earth coordinates.

proc `$`*(coords: Coordinates): string =
    runnableExamples:
        let loc = ((1'i16, 2'i16, 3'i16), (4'i16, 5'i16, 6'i16))
        doAssert $loc == r"1° 2′ 3″ N 4° 5′ 6″ E"
    let latD = if coords.lat.deg < 0: 'S' else: 'N'
    let lonD = if coords.lon.deg < 0: 'W' else: 'E'
    "$1° $2′ $3″ $4 $5° $6′ $7″ $8".format(
        coords.lat.deg, coords.lat.min, coords.lat.sec, latD,
        coords.lon.deg, coords.lon.min, coords.lon.sec, lonD
    )