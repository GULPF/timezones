import httpclient
import os
import osproc
import strformat
import sequtils
import strutils
import times
import options
import parseopt2
import tables
import timezones/private/binformat

type
    Command = enum
        cFetch = "fetch", cDump = "dump", cDiff = "diff"

const TmpDir = "/tmp/fetchtz"
const UnpackDir = TmpDir / "unpacked"
const ZicDir = TmpDir / "binary"

# Note that the legacy regions "backward" and etcetera"
# are not included by default. They can still be included
# by using the `--regions` parameter.
const DefaultRegions = @[
    "africa", "antarctica", "asia", "australasia",
    "europe", "northamerica", "southamerica", "pacificnew"
]

proc download(version: OlsonVersion) =
    let tarFile = TmpDir / fmt"{$version}.tar.gz"
    if not tarFile.fileExists:
        var http = newHttpClient()
        let url = fmt"https://www.iana.org/time-zones/repository/releases/tzdata{$version}.tar.gz"
        http.downloadFile url, tarFile
    removeDir UnpackDir
    createDir UnpackDir
    discard execProcess fmt"tar -xf {tarFile} -C {UnpackDir}"

proc zic(regions: Option[seq[string]]) =
    let files = regions.get(DefaultRegions).mapIt(UnpackDir / it).join(" ")
    discard execProcess fmt"zic -d {ZicDir} {files}"

proc processZdumpZone(tzname, content: string,
                      appendTo: var Table[string, InternalTimezone]) =
    var lineIndex = -1
    var timezone = InternalTimezone(name: tzname, transitions: @[])

    for line in content.splitLines:
        if line.len == 0: continue
        var tokens = line.splitWhitespace            
        if tokens[^1] == "NULL": continue

        lineIndex.inc
        if lineIndex != 0 and lineIndex mod 2 == 0: continue
        let format = "MMM-d-HH:mm:ss-yyyy"
        let utc = tokens[2..5].join("-").parse(format, utc()).toTime
        let adj = tokens[9..12].join("-").parse(format, utc()).toTime
        let isDst = tokens[^2] == "isdst=1"
        let offset = tokens[^1].replace("gmtoff=", "").parseInt
        timezone.transitions.add Transition(
            startUtc: utc.toUnix,
            startAdj: adj.toUnix,
            isDst: isDst,
            utcOffset: offset.int32
        )

    appendTo[tzname] = timezone

proc zdump(startYear, endYear: int32,
           tznames: Option[seq[string]]): Table[string, InternalTimezone] =
    result = initTable[string, InternalTimezone]()

    for tzfile in walkDirRec(ZicDir, {pcFile}):
        let content = execProcess fmt"zdump -v -c {startYear},{endYear} {tzfile}"
        let (dir, city, _) = tzfile.splitFile

        # Special zones like CET have no subfolder
        let tzname =
            if dir == ZicDir:
                city
            else:
                let country = dir.extractFilename
                country & "/" & city # E.g Europe/Stockholm
        
        if tznames.isSome and tzname notin tznames.get:
            continue

        processZdumpZone(tzname, content, appendTo = result)

proc parseCoordinate(str: string): Coordinate =
    var lat = $str[0]
    var lon = ""
    var i = 1
    
    while str[i] in Digits:
        lat.add str[i]
        i.inc
    lon = str[i..^1]

    result = (lat.parseInt.int32, lon.parseInt.int32)

proc zone1970(zones: Table[string, InternalTimezone]): Table[string, Location] =
    ## Parsed the ``zone1970.tab`` file and returns the locations.
    ## Only returns the locations referenced by ``zones``.
    result = initTable[string, Location]()

    for line in lines(UnpackDir / "zone1970.tab"):
        if line[0] == '#': continue
        let tokens = line.split '\t'
        let (ccStr, coordStr, tzname) = (tokens[0], tokens[1], tokens[2])
        if tzname notin zones: continue

        let position = parseCoordinate(coordStr)
        let cc = ccStr.split(',').mapIt(it.CountryCode)

        result[tzname] = initLocation(tzname, position, cc)

proc fetchTimezoneDatabase*(version: OlsonVersion, dest = ".",
                            startYear, endYear: int32,
                            tznames, regions: Option[seq[string]],
                            formatKind: FormatKind) =
    createDir TmpDir
    removeDir ZicDir
    removeFile dest
    download version
    zic regions
    let zones = zdump(startYear, endYear, tznames)
    let locations = zone1970(zones)
    let db = initOlsonDatabase(version, startYear, endYear, zones, locations)
    db.saveToFile(dest, formatKind)

const helpMsg = """
Commands:
    dump  <file>          # Print info about a tzdb file
    fetch <version>       # Download and process a tzdb file
    diff  <file1> <file2> # Compare two tzdb files (not implemented)
    --help                # Print this help message

Fetch parameters:
    --startYear:<year>    # Only store transitions starting from this year.
    --endYear:<year>      # Only store transitions until this year.
    --out:<file>          # Write output to this file.
    --timezones:<zones>   # Only use these timezones.
    --regions:<regions>   # Only use these regions.
    --json                # Store transitions as JSON (required for JS support).
"""

type
    CliOptions = object
        command: Command
        arguments: seq[string]
        startYear: int32
        endYear: int32
        outfile: Option[string]
        tznames: Option[seq[string]]
        regions: Option[seq[string]]
        formatKind: FormatKind

const DefaultOptions = CliOptions(
    arguments: newSeq[string](),
    startYear: 1500,
    endYear: 2066,
    formatKind: fkBInary
)

proc getCliOptions(): CliOptions =
    result = DefaultOptions
    var hasCommand = false

    for kind, key, val in getopt():
        try:
            case kind
            of cmdArgument:
                if not hasCommand:
                    result.command = parseEnum[Command](key)
                    hasCommand = true
                else:
                    result.arguments.add key
            of cmdLongOption, cmdShortOption:
                case key
                of "help", "h":
                    echo helpMsg
                    quit()
                of "startYear": result.startYear = val.parseInt.int32
                of "endYear": result.endYear = val.parseInt.int32
                of "out": result.outfile = some(val)
                of "timezones": result.tznames = some(val.splitWhitespace)
                of "regions": result.regions = some(val.splitWhitespace)
                of "json": result.formatKind = fkJson
                else: raise newException(ValueError, "Bad input")
            of cmdEnd: assert(false) # cannot happen
        except:
            case kind
            of cmdArgument:
                echo fmt"Invalid command: {key}"
                quit(QuitFailure)
            of cmdLongOption, cmdShortOption:
                let flag =
                    if kind == cmdLongOption:
                        "--" & key
                    else:
                        "-" & key

                let value =
                    if val == "":
                        ""
                    else:
                        ":" & val

                echo ""
                echo fmt"Invalid parameter: {flag}{value}"
                echo ""
                echo helpMsg
                echo ""
                quit(QuitFailure)
            of cmdEnd: assert(false) # cannot happen            

    if not hasCommand:
        echo "Wrong usage."
        echo helpMsg
        quit()

when isMainModule:

    var opts = getCliOptions()

    case opts.command
    of cDump:
        doAssert opts.arguments.len == 1
        let (status, db) = binformat.readFromFile(opts.arguments[0])
        let path = opts.arguments[0]
        echo ""
        echo fmt"Meta data for file '{path}'"
        echo ""
        echo fmt"Version:             {$db.version:>8}"
        echo fmt"Start year:          {db.startYear:>8}"
        echo fmt"End year:            {db.endYear:>8}"
        echo fmt"Size:                {path.getFileSize div 1000:>6}kB"
        echo fmt"Transition format:   {$db.fk:>8}"
        echo fmt"Number of timezones: {db.timezones.len:>8}"
        echo fmt"Number of locations: {db.locations.len:>8}"
        echo ""
    of cFetch:
        doAssert opts.arguments.len == 1
        echo "Fetching and processing timezone data. This might take a while..."
        let version = parseOlsonVersion(opts.arguments[0])
        let extension =
            if opts.formatKind == fkJson:
                ".json.bin"
            else:
                ".bin"
        let defaultFilePath = getCurrentDir() / ($version & extension)
        let filePath = opts.outfile.get(defaultFilePath)
        fetchTimezoneDatabase(version, filePath, opts.startYear,
            opts.endYear, opts.tznames, opts.regions, opts.formatKind)
    of cDiff:
        doAssert opts.arguments.len == 2
        echo "Not implemented"
        quit(QuitFailure)
