import std / strformat

type

    Dms* = object ## A coordinate specified
                  ## in degrees (deg), minutes (min) and seconds (sec).
        deg*, min*, sec*: int16

    Coordinates* = object ## Earth coordinates.
        lat*, lon*: Dms

proc initCoordinates*(lat, lon: (int16, int16, int16)): Coordinates =
    ## Create a coordinates object.
    result.lat = Dms(deg: lat[0], min: lat[1], sec: lat[2])
    result.lon = Dms(deg: lon[0], min: lon[1], sec: lon[2])

proc `$`*(coords: Coordinates): string =
    ## Human-friendly stringification of coordinates.
    runnableExamples:
        let loc = initCoordinates((1'i16, 2'i16, 3'i16), (4'i16, 5'i16, 6'i16))
        doAssert $loc == r"1° 2′ 3″ N 4° 5′ 6″ E"
    let latD = if coords.lat.deg < 0: 'S' else: 'N'
    let lonD = if coords.lon.deg < 0: 'W' else: 'E'
    result = fmt"{coords.lat.deg}° {coords.lat.min}′ {coords.lat.sec}″ {latD} " &
             fmt"{coords.lon.deg}° {coords.lon.min}′ {coords.lon.sec}″ {lonD}"
