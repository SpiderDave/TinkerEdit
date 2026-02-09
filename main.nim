import
    os, strutils, strformat,
    resource/resource,
    json,
    zippy,
    parseopt

import appinfo
import TinkerMap

# ======================
# CONFIG
# ======================

let prettyPrintJson = true
let minifyJsonOnBuild = true

var compressionLevel = BestSpeed

let app = newApp(
    name = "TinkerEdit",
    url = "https://github.com/SpiderDave/TinkerEdit",
    author = "SpiderDave",
    stage = "beta-release",
    description = "Tinkerlands Save Edit Tool"
)

# ======================
# HELPERS
# ======================

proc bytesToString(b: seq[byte]): string =
    result = newString(b.len)
    for i in 0 ..< b.len:
        result[i] = char(b[i])

proc stringToBytes(s: string): seq[byte] =
    result = newSeq[byte](s.len)
    for i in 0 ..< s.len:
        result[i] = byte(s[i])

proc readCString(data: seq[byte], pos: var int): string =
    let start = pos
    while pos < data.len and data[pos] != 0:
        inc pos
    result = bytesToString(data[start ..< pos])
    inc pos   # skip null terminator

proc writeCString(s: string, buf: var seq[byte]) =
    buf.add stringToBytes(s)
    buf.add 0

# ======================
# COMPRESSION / DECOMPRESSION
# ======================

proc decompressToBytes(inPath: string): seq[byte] =
    let compressedStr = readFile(inPath)

    var compressed = newSeq[uint8](compressedStr.len)
    for i, c in compressedStr:
        compressed[i] = uint8(c)

    let decompressed = uncompress(compressed, dfDetect)

    result = newSeq[byte](decompressed.len)
    for i in 0 ..< decompressed.len:
        result[i] = byte(decompressed[i])

proc compressToFile(data: seq[byte], outPath: string, level:int) =
    var input = newSeq[uint8](data.len)
    for i in 0 ..< data.len:
        input[i] = uint8(data[i])

    let compressed = compress(input, level, dfZlib)

    var f = open(outPath, fmWrite)
    defer: f.close()
    discard f.writeBuffer(compressed[0].addr, compressed.len)

# ======================
# STRING-BASED JSON PRETTY / MINIFY
# ======================

proc minifyJson(s: string): string =
    var res = newString(0)
    var inString = false
    var escape = false

    for c in s:
        if escape:
            res.add c
            escape = false
        elif c == '\\':
            res.add c
            escape = true
        elif c == '"':
            res.add c
            inString = not inString
        elif inString:
            res.add c
        elif c notin {' ', '\n', '\r', '\t'}:
            res.add c

    result = res

proc prettyJson(s: string, indentStep = 2): string =
    var res = newString(0)
    var inString = false
    var escape = false
    var indent = 0
    var i = 0

    while i < s.len:
        let c = s[i]

        if escape:
            res.add c
            escape = false
        elif c == '\\':
            res.add c
            escape = true
        elif c == '"':
            res.add c
            inString = not inString
        elif inString:
            res.add c
        elif c in {'{', '['}:
            # Check for empty brackets
            var j = i + 1
            while j < s.len and s[j] in {' ', '\n', '\r', '\t'}:
                inc j
            if j < s.len and ((c == '{' and s[j] == '}') or (c == '[' and s[j] == ']')):
                res.add c & s[j]
                i = j  # skip the closing bracket
            else:
                res.add c
                indent += indentStep
                res.add '\n' & repeat(" ", max(indent, 0))
        elif c in {'}', ']'}:
            indent -= indentStep
            res.add '\n' & repeat(" ", max(indent, 0)) & c
        elif c == ',':
            res.add c & '\n' & repeat(" ", max(indent, 0))
        elif c == ':':
            res.add ": "
        elif c notin {' ', '\n', '\r', '\t'}:
            res.add c

        inc i

    result = res

# ======================
# TYPES
# ======================

type
    Chunk = object
        name: string
        payload: seq[byte]

# ======================
# CHUNK MARKERS
# ======================

let chunkNames = [
    "SHARED_DATA",
    "BASIC_DATA",
    "STRUCTS",
    "GRIDS_BUFFERS_GENERAL",
    "MINIMAP_GENERAL",
    "GRIDS_BUFFERS_SHIP",
    "MINIMAP_SHIP",
    "END"
]

var chunkMarkers: seq[seq[byte]] = @[]

proc initMarkers() =
    chunkMarkers = @[]
    for name in chunkNames:
        chunkMarkers.add stringToBytes("@" & name & "@\0")

proc findMarkerAt(data: seq[byte], marker: seq[byte], idx: int): bool =
    if idx + marker.len > data.len:
        return false
    for i in 0 ..< marker.len:
        if data[idx + i] != marker[i]:
            return false
    true

# ======================
# PARSING
# ======================

proc parseChunks(data: seq[byte]): seq[Chunk] =
    result = @[]
    var pos = 0

    while pos < data.len:
        if data[pos] != byte('@'):
            inc pos
            continue

        var foundIdx = -1
        for i in 0 ..< chunkMarkers.len:
            if findMarkerAt(data, chunkMarkers[i], pos):
                foundIdx = i
                break

        if foundIdx == -1:
            inc pos
            continue

        let marker = chunkMarkers[foundIdx]
        let payloadStart = pos + marker.len

        var nextPos = data.len
        for scan in payloadStart ..< data.len:
            if data[scan] == byte('@'):
                for m in chunkMarkers:
                    if findMarkerAt(data, m, scan):
                        nextPos = scan
                        break
                if nextPos != data.len:
                    break

        let payload = data[payloadStart ..< nextPos]
        echo "Found chunk: ", chunkNames[foundIdx], ", payload length: ", payload.len

        result.add Chunk(name: chunkNames[foundIdx], payload: payload)
        pos = nextPos

# ======================
# GRID BUFFERS (SPECIAL)
# ======================

proc extractGridBuffers(name: string, payload: seq[byte]) =
    var pos = 0
    var index = 1

    while pos < payload.len:
        let typ = readCString(payload, pos)

        var header = typ
        if typ == "0" or typ == "1":
            let w = readCString(payload, pos)
            let h = readCString(payload, pos)
            header &= " " & w & " " & h

        let data = readCString(payload, pos)

        let headerFile = fmt"data/{name}.{index}.header.txt"
        let dataFile   = fmt"data/{name}.{index}.txt"

        writeFile(headerFile, header)
        writeFile(dataFile, data)

        echo "Wrote ", headerFile / ""
        echo "Wrote ", dataFile / ""

        inc index

proc buildGridBuffers(name: string): seq[byte] =
    result = @[]
    var index = 1

    while true:
        let headerFile = fmt"data/{name}.{index}.header.txt"
        let dataFile   = fmt"data/{name}.{index}.txt"

        if not fileExists(headerFile):
            break

        let headerParts = readFile(headerFile).splitWhitespace()
        let typ = headerParts[0]

        writeCString(typ, result)

        if typ == "0" or typ == "1":
            writeCString(headerParts[1], result)
            writeCString(headerParts[2], result)

        let data = readFile(dataFile)
        writeCString(data, result)

        inc index

# ======================
# SEGMENT FORMAT CONFIG
# ======================

let sharedDataFormats       = @["json", "json", "json"]
let basicDataFormats        = @["text","text","text","text","text","text","text","text","json","json","image"]
let structsFormats          = @["json","json","json","json","json","json","json","json","json","text","text","json"]

# ======================
# FLEXIBLE SEGMENTS
# ======================

proc parseFlexible(payload: seq[byte], numParts: int): seq[seq[byte]] =
    var parts: seq[seq[byte]] = @[]
    var start = 0

    for i, b in payload:
        if b == 0:
            parts.add payload[start ..< i]
            start = i + 1

    if start < payload.len:
        parts.add payload[start ..< payload.len]

    while parts.len < numParts:
        parts.add @[]

    result = parts

proc buildFlexible(parts: seq[seq[byte]]): seq[byte] =
    result = @[]
    for part in parts:
        result.add part
        result.add 0

# ======================
# EXTRACT / BUILD SEGMENTS
# ======================

proc extractSegment(name: string, payload: seq[byte], formats: seq[string]) =
    let parts = parseFlexible(payload, formats.len)

    if not dirExists("data"):
        createDir("data")

    for i, s in parts:
        let ext =
            case formats[i]
            of "json":  ".json"
            of "dat":   ".dat"
            of "image": ".png"
            of "text": ".txt"
            else: ""
        
        let outFile = fmt"data/{name}.{i+1}{ext}"

        var text = bytesToString(s)
        if ext == ".json" and prettyPrintJson:
            text = prettyJson(text)

        # preview file
        if name == "BASIC_DATA" and i+1 == 11:
            decodeMap(text, fmt"{name}.{i+1}", 0, 0, "data")
        else:
            writeFile(outFile, text)
            echo "Wrote ", outFile / "", " (", text.len, " bytes)"

proc buildSegment(name: string, formats: seq[string]): seq[byte] =
    var parts: seq[seq[byte]] = @[]

    for i in 0 ..< formats.len:
        let ext =
            case formats[i]
            of "json":  ".json"
            of "dat":   ".dat"
            of "image": ".png"
            of "text": ".txt"
            else: ""

        # preview file
        if name == "BASIC_DATA" and i+1 == 11:
            let fileName = fmt"data/{name}.{i+1}.png"
            
            var imageFiles: seq[string] = @[]
            imageFiles.add(fileName)
            
            parts.add rebuildMap(imageFiles)
        else:
            let fileName = fmt"data/{name}.{i+1}{ext}"
            
            var text = readFile(fileName)
            if ext == ".json" and minifyJsonOnBuild:
                text = minifyJson(text)

            parts.add stringToBytes(text)

    result = buildFlexible(parts)

# ======================
# EXTRACTION
# ======================

proc extract(filename: string) =
    initMarkers()
    let raw = decompressToBytes(filename)
    let chunks = parseChunks(raw)
    
    if not dirExists("data"):
        createDir("data")

    for c in chunks:
        case c.name
        of "SHARED_DATA":
            extractSegment(c.name, c.payload, sharedDataFormats)
        of "BASIC_DATA":
            extractSegment(c.name, c.payload, basicDataFormats)
        of "STRUCTS":
            extractSegment(c.name, c.payload, structsFormats)
        of "GRIDS_BUFFERS_GENERAL", "GRIDS_BUFFERS_SHIP":
            extractGridBuffers(c.name, c.payload)
        of "MINIMAP_GENERAL", "MINIMAP_SHIP":
            decodeMap(bytesToString(c.payload), c.name, 0, 0, "data")
        else:
            discard

# ======================
# BUILD
# ======================

proc build(filename: string) =
    initMarkers()
    var chunks: seq[Chunk] = @[]

    for name in chunkNames:
        var payload: seq[byte]
        case name
        of "SHARED_DATA":
            payload = buildSegment(name, sharedDataFormats)
        of "BASIC_DATA":
            payload = buildSegment(name, basicDataFormats)
        of "STRUCTS":
            payload = buildSegment(name, structsFormats)
        of "GRIDS_BUFFERS_GENERAL", "GRIDS_BUFFERS_SHIP":
            payload = buildGridBuffers(name)
        of "END":
            payload = @[]
        of "MINIMAP_GENERAL":
            let imageFiles = @[
                "data/MINIMAP_GENERAL.1.png",
                "data/MINIMAP_GENERAL.2.png",
                "data/MINIMAP_GENERAL.3.png",
                "data/MINIMAP_GENERAL.4.png",
                "data/MINIMAP_GENERAL.5.png",
                "data/MINIMAP_GENERAL.6.png"
            ]
            payload = rebuildMap(imageFiles)
        of "MINIMAP_SHIP":
            let imageFiles = @[
                "data/MINIMAP_SHIP.1.png",
                "data/MINIMAP_SHIP.2.png"
            ]
            
            payload = rebuildMap(imageFiles)
        else:
            payload = stringToBytes(readFile(fmt"data/{name}.dat"))


        chunks.add Chunk(name: name, payload: payload)

    var rebuiltData: seq[byte] = @[]

    for c in chunks:
        rebuiltData.add stringToBytes("@" & c.name & "@\0")
        rebuiltData.add c.payload
        echo "Chunk ", c.name, ": payload=", c.payload.len, " rebuiltData=", rebuiltData.len
    
    echo "Compressing..."
    compressToFile(rebuiltData, filename, compressionLevel)
    echo fmt"Wrote to {filename}"

# ======================
# MAIN
# ======================

var
  filename = ""
  cmd = ""

# Initialize parser
var p = initOptParser(commandLineParams())

for kind, key, val in p.getopt():
  case kind
  of cmdArgument:
    discard
  of cmdLongOption, cmdShortOption:
    case key
    of "extract", "x":
      cmd = "extract"
      if val.len > 0:          # capture the value if passed
        filename = val
    of "build", "b":
      cmd = "build"
      if val.len > 0:          # capture the value if passed
        filename = val
    of "releasetag": # undocumented
      cmd = "releasetag"
    of "level", "l":
      if val == "speed":
        compressionLevel = BestSpeed
      elif val == "best":
        compressionLevel = BestCompression
    of "help", "h":
        cmd = "help"
    of "usage": # undocumented
        cmd = "usage"
    else:
      echo "Unknown option: \n", key
      cmd = "usage"
  of cmdEnd:
    break


proc info() =
  echo fmt"{app.name} {app.version} by {app.author} ({app.url})"
  echo ""
  echo "Command-line save editor and rebuild tool for Tinkerlands."
  echo ""

proc usage() =
  echo "Usage: TinkerEdit [opts]"
  echo ""
  echo "Options:"
  echo "  -x, --extract:filename          extract save file (default: main.sav)"
  echo "  -x, --extract:worldnumber       extract save file by world number"
  echo "  -b, --build:filename            rebuild save file (default: main_new.sav)"
  echo "  -l, --level:best|speed          compression level (default: speed)"
  echo "  -h, --help                      show this help"
  echo ""
  echo "Examples:"
  echo "  TinkerEdit -x"
  echo "  TinkerEdit -x:1"
  echo "  TinkerEdit -x:main.sav"
  echo "  TinkerEdit -b:main_new.sav --level=speed"

# Execute the selected command
if cmd == "releasetag":
  echo app.releaseTag
elif cmd == "extract":
  var extractFile: string
  if filename in @["1","2","3","4"]:
    let saveNum = filename
    let localApp = getEnv("localappdata")
    extractFile = fmt"{localApp}/Tinkerlands/worlds/savegame0{saveNum}/main.sav"
  else:
    extractFile = if filename.len > 0: filename else: "main.sav"

  extract(extractFile)
elif cmd == "extract2":
  var extractFile = if filename.len > 0: filename else: "main.sav"

  # Special handling for numeric save numbers
  if extractFile in @["1","2","3","4"]:
    let saveNum = extractFile
    let localApp = getEnv("localappdata")
    if localApp.len == 0:
      quit "Error: LOCALAPPDATA environment variable not set"
    extractFile = fmt"{localApp}/Tinkerlands/worlds/savegame0{saveNum}/main.sav"
  extract(extractFile)
elif cmd == "build":
  build(if filename.len > 0: filename else: "main_new.sav")
elif cmd == "help":
  info()
  usage()
elif cmd == "usage":
  usage()
else:
  info()
  usage()
