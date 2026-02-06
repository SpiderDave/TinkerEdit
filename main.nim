import
    os, strutils, strformat,
    resource/resource,
    json,
    zippy

import appinfo
import TinkerMap

# ======================
# CONFIG
# ======================

let prettyPrintJson = true
let minifyJsonOnBuild = true

let app = newApp(
    name = "TinkerEdit",
    url = "no url",
    author = "SpiderDave",
    stage = "alpha-release",
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

proc compressToFile(data: seq[byte], outPath: string) =
    var input = newSeq[uint8](data.len)
    for i in 0 ..< data.len:
        input[i] = uint8(data[i])

    let compressed = compress(input, BestCompression, dfZlib)

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
        if c.name == "END":
            continue
        elif c.name == "SHARED_DATA":
            extractSegment(c.name, c.payload, sharedDataFormats)
        elif c.name == "BASIC_DATA":
            extractSegment(c.name, c.payload, basicDataFormats)
        elif c.name == "STRUCTS":
            extractSegment(c.name, c.payload, structsFormats)
        elif c.name == "MINIMAP_GENERAL" or c.name == "MINIMAP_SHIP":
            decodeMap(bytesToString(c.payload), c.name, 0, 0, "data")
        else:
            let outFile = fmt"data/{c.name}.dat"
            writeFile(outFile, c.payload)
            echo "Wrote ", outFile / "", " (", c.payload.len, " bytes)"

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
    compressToFile(rebuiltData, filename)
    echo fmt"Wrote to {filename}"

# ======================
# MAIN
# ======================

let cmd = if paramCount() >= 1: paramStr(1) else: ""
let file = if paramCount() >= 2: paramStr(2) else: ""

case cmd
of "-extract":
    extract(if file.len > 0: file else: "input.bin")
of "-build":
    build(if file.len > 0: file else: "output.bin")
of "-releasetag":
    echo app.releaseTag
else:
    echo app.name, " ", app.version
    echo "by ", app.author, "\n"
    echo "Usage: TinkerEdit -extract|-build [filename]"
