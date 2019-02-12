# This file deals with the zone1970.tab file which assigns each timezone id
# to some coordinates and a list of countries. The zone1970.tab file is part
# of the tzdb distribution.

import std / [strutils, sequtils, parseutils, tables, options]
import coordinates, timezonedbs

proc parseCoordinate(str: string): Coordinates =
    template parse(s: string): int16 =
        s.parseInt.int16
    case str.len
    of "+DDMM+DDDMM".len:
        let lat = (str[0..2].parse, str[3..4].parse,  0'i16)
        let lon = (str[5..8].parse, str[9..10].parse, 0'i16)
        result = initCoordinates(lat, lon)
    of "+DDMMSS+DDDMMSS".len:
        let lat = (str[0..2].parse,  str[3..4].parse,   str[5..6].parse)
        let lon = (str[7..10].parse, str[11..12].parse, str[13..14].parse)
        result = initCoordinates(lat, lon)
    else:
        raise newException(ValueError, "Invalid coordinate format: " & str)

proc parseCountries(str: string): seq[CountryCode] =
    result = str
        .split(',')
        .filterIt(it.len == 2) # Wrong country codes are silently ignored
        .mapIt(cc(it))

proc extractSingleLocation*(path: string, tzName: string):
                            Option[(Coordinates, seq[CountryCode])] =
    for line in lines(path):
        if line[0] == '#': continue
        let tokens = line.split '\t'
        let (ccStr, coordStr, tzName2) = (tokens[0], tokens[1], tokens[2])
        if tzName2 == tzName:
            let coord = parseCoordinate(coordStr)
            let countries = parseCountries(ccStr)
            return some((coord, countries))

proc extractAllLocations*(path: string):
                          Table[string, (Coordinates, seq[CountryCode])] =
    result = initTable[string, (Coordinates, seq[CountryCode])]()
    for line in lines(path):
        if line[0] == '#': continue
        let tokens = line.split '\t'
        let (ccStr, coordStr, tzName) = (tokens[0], tokens[1], tokens[2])
        let coord = parseCoordinate(coordStr)
        let countries = parseCountries(ccStr)
        result[tzName] = (coord, countries)