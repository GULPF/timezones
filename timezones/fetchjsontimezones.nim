import std / [httpclient, os, osproc, strformat, sequtils, strutils, times,
    options,  parseopt,  tables]
import private / [timezonefile, coordinates, zone1970, posixtimezones_impl]

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

proc download(version: string) =
    let tarFile = TmpDir / fmt"{version}.tar.gz"
    if not tarFile.fileExists:
        var http = newHttpClient()
        let url = fmt"https://www.iana.org/time-zones/repository/releases/tzdata{version}.tar.gz"
        http.downloadFile url, tarFile
    removeDir UnpackDir
    createDir UnpackDir
    doAssert execCmd(fmt"tar -xf {tarFile} -C {UnpackDir}") == 0

proc zic(regions: Option[seq[string]]) =
    let files = regions.get(DefaultRegions).mapIt(UnpackDir / it).join(" ")
    doAssert execCmd(fmt"zic -d {ZicDir} {files}") == 0

proc processZdumpZone(tzname, content: string,
                      appendTo: var Table[string, TimezoneData]) =
    var lineIndex = -1
    var timezone = TimezoneData(name: tzname, transitions: @[], countries: @[])

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
           tznames: Option[seq[string]]): Table[string, TimezoneData] =
    result = initTable[string, TimezoneData]()

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

proc loadZicOutput(tznames: Option[seq[string]]): Table[string, TimezoneData] =
    result = initTable[string, TimezoneData]()
    for tzfile in walkDirRec(ZicDir, {pcFile}):
        let (dir, city, _) = tzfile.splitFile

        # Special zones like CET have no subfolder
        let tzname =
            if dir == ZicDir:
                city
            else:
                let country = dir.extractFilename
                country & "/" & city # E.g Europe/Stockholm

        if tznames.isSome and tzname notin tznames.get:
            let info = loadTzInfoImpl(tzfile)
            # result[tzname] = TimezoneData(
            #     transitions
            # )

proc loadZone1970(zones: var Table[string, TimezoneData]) =
    ## Parses the ``zone1970.tab`` file and sets the locations.
    let path = UnpackDir / "zone1970.tab"
    for countries, coords, tzName of zone1970Entries(path):
        zones[tzname].coordinates = coords
        zones[tzname].countries = countries.mapIt(cc(it))

proc fetchTimezoneDatabase*(version: string, dest = ".",
                            startYear, endYear: int32,
                            tznames, regions: Option[seq[string]]) =
    createDir TmpDir
    removeDir ZicDir
    removeFile dest
    download version
    zic regions
    var zones = zdump(startYear, endYear, tznames)
    loadZone1970(zones)
    let db = initTzData(version, toSeq(zones.values))
    db.saveToFile(dest)

const helpMsg = """
    fetchjsontimezones <version> # Download <version>, e.g '2018d'.

    --help                       # Print this help message

    --startYear:<year>           # Only store transitions starting from this year.
    --endYear:<year>             # Only store transitions until this year.
    --out:<file>, -o:<file>      # Write output to this file.
                                 # Defaults to './<version>.json'.
    --timezones:<zones>          # Only store transitions for these timezones.
    --regions:<regions>          # Only store transitions for these regions.
"""

type
    CliOptions = object
        arguments: seq[string]
        startYear: int32
        endYear: int32
        outfile: Option[string]
        tznames: Option[seq[string]]
        regions: Option[seq[string]]

const DefaultOptions = CliOptions(
    arguments: newSeq[string](),
    startYear: 1500,
    endYear: 2066
)

proc getCliOptions(): CliOptions =
    result = DefaultOptions
    var hasCommand = false

    for kind, key, val in getopt():
        try:
            case kind
            of cmdArgument:
                result.arguments.add key
            of cmdLongOption, cmdShortOption:
                case key
                of "help", "h":
                    echo helpMsg
                    quit()
                of "startYear": result.startYear = val.parseInt.int32
                of "endYear": result.endYear = val.parseInt.int32
                of "out", "o": result.outfile = some(val)
                of "timezones": result.tznames = some(val.splitWhitespace)
                of "regions": result.regions = some(val.splitWhitespace)
                else: raise newException(ValueError, "Bad input")
            of cmdEnd: assert(false) # cannot happen
        except:
            case kind
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
            else: assert(false) # cannot happen            

when isMainModule:
    var opts = getCliOptions()
    doAssert opts.arguments.len == 1
    echo "Fetching and processing timezone data. This might take a while..."
    let version = opts.arguments[0]
    let defaultFilePath = getCurrentDir() / (version & ".json")
    let filePath = opts.outfile.get(defaultFilePath)
    fetchTimezoneDatabase(version, filePath, opts.startYear,
        opts.endYear, opts.tznames, opts.regions)
