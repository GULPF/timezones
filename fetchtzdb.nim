import httpclient
import os
import osproc
import strformat
import sequtils
import strutils
import times
import timezones/private/binformat

const TmpDir = "/tmp/fetchtz"
const UnpackDir = TmpDir / "unpacked"
const ZicDir = TmpDir / "binary"
const DumpDir = TmpDir / "textdump"

proc download(version: string) =
    let tarFile = TmpDir / fmt"{version}.tar.gz"
    if not tarFile.fileExists:
        var http = newHttpClient()
        let url = fmt"https://www.iana.org/time-zones/repository/releases/tzdata{version}.tar.gz"
        http.downloadFile url, tarFile
    removeDir UnpackDir
    createDir UnpackDir
    discard execProcess fmt"tar -xf {tarFile} -C {UnpackDir}"

proc zic() =
    let files = [
        "africa", "antarctica", "asia", "australasia", "etcetera",
        "europe", "northamerica", "southamerica", "pacificnew", "backward"
    ].mapIt(UnpackDir / it).join(" ")

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

proc zdump(dest, version: string, startYear, endYear: int) =
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
        
        processZdumpZone(tzname, content, appendTo = zones)
    
    let db = initOlsonDatabase(version[0..3].parseInt.int32, version[4], zones)
    db.saveToFile getCurrentDir() / dest / fmt"{version}.bin"

proc fetchTimezoneDatabase*(version: string, dest = ".", startYear = 1500, endYear = 2066) =
    createDir TmpDir
    removeDir ZicDir
    removeFile dest / fmt"{version}.bin"
    download version
    zic()
    zdump dest, version, startYear, endYear

when isMainModule:
    if paramCount() notin {1,2}:
        echo "Wrong number of arguments"
        echo "Usage: fetchtzdb <version> <dest>"
    else:
        echo "Fetching and processing timezone data. This might take a while..."
        let dest = if paramCount() == 2: paramStr(2) else: "."
        let version = paramStr(1)
        fetchTimezoneDatabase version, dest