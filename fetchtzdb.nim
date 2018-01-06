import httpclient
import os
import osproc
import strformat
import sequtils
import strutils
import times

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

proc transformTzfile(tzname, content: string, result: var string) =
    var lineIndex = -1

    for line in content.splitLines:
        if line.len == 0: continue
        var tokens = line.splitWhitespace            
        if tokens[^1] == "NULL": continue

        lineIndex.inc
        # We don't need data on both sides of the transition,
        # so we discard every second line (we still need the first one though).
        # xxx this is annoying, it means that the semantics of the first line is special
        if lineIndex != 0 and lineIndex mod 2 == 0: continue
        let format = "MMM-d-HH:mm:ss-yyyy"
        let utc = tokens[2..5].join("-").parse(format, utc())
        let adj = tokens[9..12].join("-").parse(format, utc())
        let isDst = if tokens[^2] == "isdst=1": true else: false
        let offset = tokens[^1].replace("gmtoff=", "")
        result.add [tzname, $utc.toTime.toUnix, $adj.toTime.toUnix, $isDst, $offset].join "\t"
        result.add "\n"

proc zdump(dest: string, startYear, endYear: int) =
    let txtFile = open(getCurrentDir() / dest / "zones.txt", fmWrite)
    var buffer = ""
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

        transformTzfile(tzname, content, result = buffer)
    txtFile.write(buffer)

proc fetchTimezoneDatabase*(version: string, dest = ".", startYear = 1500, endYear = 2066) =
    createDir TmpDir
    removeDir ZicDir
    removeFile dest / "zones.txt"
    download version
    zic()
    zdump dest, startYear, endYear

when isMainModule:
    if paramCount() notin {1,2}:
        echo "Wrong number of arguments"
        echo "Usage: fetchtzdb <version> <dest>"
    else:
        echo "Fetching and processing timezone data. This might take a while..."
        let dest = if paramCount() == 2: paramStr(2) else: "."
        let version = paramStr(1)
        fetchTimezoneDatabase version, dest