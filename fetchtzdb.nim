import httpclient
import os
import osproc
import strformat
import sequtils
import strutils
import times
import options
import parseopt2
import timezones/private/binformat

type
    Command = enum
        cFetch = "fetch", cDump = "dump", cDiff = "diff"

const TmpDir = "/tmp/fetchtz"
const UnpackDir = TmpDir / "unpacked"
const ZicDir = TmpDir / "binary"
const DumpDir = TmpDir / "textdump"

const DefaultRegions = @[
    "africa", "antarctica", "asia", "australasia", "etcetera",
    "europe", "northamerica", "southamerica", "pacificnew", "backward"
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

proc processZdumpZone(tzname, content: string, appendTo: var seq[InternalTimezone]) =
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

    appendTo.add timezone

proc zdump(dest: string, version: OlsonVersion,
           startYear, endYear: int32, timezones: Option[seq[string]],
           formatKind: FormatKind) =
    var zones = newSeq[InternalTimezone]()

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
        
        if timezones.isSome and tzname notin timezones.get:
            continue

        processZdumpZone(tzname, content, appendTo = zones)

    let db = initOlsonDatabase(version, startYear, endYear, zones)
    db.saveToFile(dest, formatKind)

proc fetchTimezoneDatabase*(version: OlsonVersion, dest = ".",
                            startYear, endYear: int32,
                            timezones, regions: Option[seq[string]],
                            formatKind: FormatKind) =
    createDir TmpDir
    removeDir ZicDir
    removeFile dest
    download version
    zic regions
    zdump dest, version, startYear, endYear, timezones, formatKind

const helpMsg = """
Commands:
    dump <file>          # Print info about tzdb file
    fetch <version>      # Download and process a tzdb file
    diff <file1> <file2> # Compare two tzdb files
"""

when isMainModule:

    var command: Option[Command]
    var arguments = newSeq[string]()
    var startYear = 1500'i32
    var endYear = 2066'i32
    var outfile: Option[string]
    var timezones: Option[seq[string]]
    var regions: Option[seq[string]]
    var formatKind = fkBinary

    for kind, key, val in getopt():
        case kind
        of cmdArgument:
            if command.isNone:
                command = some(parseEnum[Command](key))
            else:
                arguments.add key
        of cmdLongOption, cmdShortOption:
            case key
            of "help", "h":
                echo helpMsg
                quit()
            of "startYear": startYear = val.parseInt.int32
            of "endYear": endYear = val.parseInt.int32
            of "out": outfile = some(val)
            of "timezones": timezones = some(val.splitWhitespace)
            of "regions": regions = some(val.splitWhitespace)
            of "json": formatKind = fkJson
        of cmdEnd: assert(false) # cannot happen

    if not command.isSome:
        echo "Wrong usage."
        echo helpMsg
        quit()

    case command.get
    of cDump:
        doAssert arguments.len == 1
        let (status, db) = binformat.readFromFile(arguments[0])
        let path = arguments[0]
        echo ""
        echo fmt"Meta data for file '{path}'"
        echo ""
        echo fmt"Version:    {db.version:>8}"
        echo fmt"Start year: {db.startYear:>8}"
        echo fmt"End year:   {db.endYear:>8}"
        echo fmt"Size:       {path.getFileSize div 1000:>6}kB"
    of cFetch: # download release
        doAssert arguments.len == 1
        echo "Fetching and processing timezone data. This might take a while..."
        let version = parseOlsonVersion(arguments[0])
        let filePath = outfile.get(getCurrentDir() / ($version & ".bin"))
        fetchTimezoneDatabase(version, filePath,
            startYear, endYear, timezones, regions, formatKind)
    of cDiff:
        doAssert arguments.len == 2
        echo "Not implemented"
        quit(QuitFailure)
