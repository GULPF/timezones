# This file contains some data types and procs that are needed by
# ``timezonefile`` but also need to be exported by the end user.
# This seperation is done so that ``include`` can be abused for doc gen.

import strutils

type

    Dms* = tuple[deg, min, sec: int16] ## A coordinate specified
            ## in degrees (deg), minutes (min) and seconds (sec).
    Coordinates* = tuple[lat, lon: Dms] ## Earth coordinates.

    CountryCodeImpl = distinct array[2, char]
    CountryCode* = CountryCodeImpl ## Two character country code,
            ## using ISO 3166-1 alpha-2.
            ## Use ``$`` to get the raw country code.
            ##
            ## See https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2.

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

proc `==`*(a, b: CountryCode): bool {.borrow.}
    ## Compare two country codes.

proc cc*(str: string): CountryCode =
    ## Create a ``CountryCode`` from its string representation.
    ## Note that ``str`` is not validated except for it's length.
    ## This means that even country codes that (currently) doesn't exist
    ## in ISO 3166-1 alpha-2 (like ``YX``, ``YZ``, etc) are accepted.
    runnableExamples:
        let usa = cc"US"
        doAssert $usa == "US"
    if str.len != 2:
        raise newException(ValueError,
            "Country code must be exactly two characters: " & str)
    let arr = [str[0], str[1]]
    result = arr.CountryCode

proc `$`*(cc: CountryCode): string =
    ## Get the string representation of ``cc``.
    runnableExamples:
        let usa = cc"US"
        doAssert $usa == "US"
    let arr = array[2, char](cc)
    arr[0] & arr[1]