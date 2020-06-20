when not defined(posix):
    when isMainModule:
        echo "fetchjsontimezones is only available for posix systems"
else:
    import std / [httpclient, os, osproc, strformat, sequtils, strutils,
        options,  parseopt]
    import private / [timezonedbs, coordinates]
    import posixtimezones

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
            let url = "https://www.iana.org/time-zones/repository/releases/" &
                fmt"tzdata{version}.tar.gz"
            http.downloadFile url, tarFile
        removeDir UnpackDir
        createDir UnpackDir
        doAssert execCmd(fmt"tar -xf {tarFile} -C {UnpackDir}") == 0

    proc zic(regions: Option[seq[string]]) =
        let files = regions.get(DefaultRegions).mapIt(UnpackDir / it).join(" ")
        doAssert execCmd(fmt"zic -d {ZicDir} {files}") == 0

    proc fetchTimezoneDatabase*(version, dest: string,
                                tznames, regions: Option[seq[string]]) =
        createDir TmpDir
        removeDir ZicDir
        removeFile dest
        download version
        zic regions
        if tznames.isSome:
            let toKeep = tznames.get
            var toDelete = newSeq[string]()
            for path in walkDirRec(ZicDir, relative = true):
                if path notin toKeep:
                    toDelete.add path
            for path in toDelete:
                removeFile ZicDir / path
        copyFile(UnpackDir / "zone1970.tab", ZicDir / "zone1970.tab")
        var db = TimezoneDb(loadPosixTzDb(ZicDir))
        # Need to set the version manually as `loadPosixTzDb` don't know about it
        db.version = version
        db.saveToFile(dest)

    const helpMsg = """
        fetchjsontimezones <version> # Download <version>, e.g '2018d'.

        --help                       # Print this help message
        --out:<file>, -o:<file>      # Write output to this file.
                                    # Defaults to './<version>.json'.
        --timezones:<zones>          # Only store transitions for these timezones.
        --regions:<regions>          # Only store transitions for these regions.
    """

    type
        CliOptions = object
            arguments: seq[string]
            outfile: Option[string]
            tznames: Option[seq[string]]
            regions: Option[seq[string]]

    const DefaultOptions = CliOptions(
        arguments: newSeq[string](),
    )

    proc getCliOptions(): CliOptions =
        result = DefaultOptions

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
        fetchTimezoneDatabase(version, filePath, opts.tznames, opts.regions)
