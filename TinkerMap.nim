# TinkerMap: Minimap Extractor & Rebuilder for Tinkerlands
#
# File format:
# -----------------------------------------------
# - Each map or layer is stored in repeated blocks:
#     "2"       (byte value 0x32)
#     0x00      (null byte)
#     <base64>  (Base64-encoded RGBA pixel data)
#     0x00      (null byte)
# - Normal map files contain multiple maps (e.g., overworld, caves, pyramids, and their discovered masks)
# - Ship maps contain fewer maps
# - Each pixel is 4 bytes (RGBA)
# - If width/height are not supplied, the program assumes the map is square
#   and infers dimensions from the decoded data length
# - Rebuild mode allows reconstructing the .dat file from the numbered PNG outputs
# - If a file does not start with "2" + 0x00, it is treated as a single Base64 image without null bytes
# -----------------------------------------------

import os, strutils, base64, strformat, math
import pixie

# ----------------------------------------------------------------
# Decode from raw bytes, optional output folder
# ----------------------------------------------------------------
proc decodeMap*(data: string, baseName: string, width: int = 0, height: int = 0, outFolder: string = "") =
  var offset = 0
  var mapIndex = 1  # Start numbering at 1

  if data.len >= 2 and data[0] == '2' and data[1] == '\x00':
    # Multi-map file
    while offset < data.len:
      let startIdx = data.find("2", offset)
      if startIdx < 0 or startIdx + 1 >= data.len:
        break
      if data[startIdx + 1] != '\x00':
        offset = startIdx + 1
        continue

      let base64Start = startIdx + 2
      let base64End = data.find("\x00", base64Start)
      if base64End < 0:
        break

      let base64Chunk = data[base64Start ..< base64End]
      let decodedBytes = decode(base64Chunk)

      var MapWidth = width
      var MapHeight = height
      if MapWidth == 0 or MapHeight == 0:
        let numPixels = decodedBytes.len div 4
        let side = int(math.sqrt(float(numPixels)))
        MapWidth = side
        MapHeight = side
        if MapWidth * MapHeight * 4 != decodedBytes.len:
          echo "Warning: decoded data length does not form a perfect square, using nearest integer side: ", side

      var img = newImage(MapWidth, MapHeight)
      var idx = 0
      for y in 0..<MapHeight:
        for x in 0..<MapWidth:
          if idx + 3 >= decodedBytes.len:
            break
          let r = decodedBytes[idx].ord.uint8
          let g = decodedBytes[idx+1].ord.uint8
          let b = decodedBytes[idx+2].ord.uint8
          let a = decodedBytes[idx+3].ord.uint8
          img.data[MapWidth * y + x] = ColorRGBX(r: r, g: g, b: b, a: a)
          idx += 4

      let outputFile = outFolder / fmt"{baseName}.{mapIndex}.png"
      img.writeFile(outputFile)
      echo "Wrote to ", (if outFolder.len > 0: outputFile else: fmt"{baseName}.{mapIndex}.png")

      mapIndex += 1
      offset = base64End + 1

  else:
    # Single-image fallback
    echo "File does not start with '2' + 0x00, treating as single Base64 image"
    let decodedBytes = decode(data)

    var MapWidth = 320
    var MapHeight = 180
    let expectedLength = MapWidth * MapHeight * 4
    if decodedBytes.len != expectedLength:
      let numPixels = decodedBytes.len div 4
      let side = int(math.sqrt(float(numPixels)))
      MapWidth = side
      MapHeight = side
      if MapWidth * MapHeight * 4 != decodedBytes.len:
        echo "Warning: decoded data length does not match 320x180, using nearest integer square side: ", side

    var img = newImage(MapWidth, MapHeight)
    var idx = 0
    for y in 0..<MapHeight:
      for x in 0..<MapWidth:
        if idx + 3 >= decodedBytes.len:
          break
        let r = decodedBytes[idx].ord.uint8
        let g = decodedBytes[idx+1].ord.uint8
        let b = decodedBytes[idx+2].ord.uint8
        let a = decodedBytes[idx+3].ord.uint8
        img.data[MapWidth * y + x] = ColorRGBX(r: r, g: g, b: b, a: a)
        idx += 4

    let outputFile = outFolder / fmt"{baseName}.png"
    img.writeFile(outputFile)
    echo "Wrote to ", (if outFolder.len > 0: outputFile else: fmt"{baseName}.png")

# ----------------------------------------------------------------
# Decode from file, optional folder
# ----------------------------------------------------------------
proc decodeMapFile*(filename: string, width: int = 0, height: int = 0, outFolder: string = "") =
  let data = readFile(filename)
  let baseName = filename.splitFile[1]
  decodeMap(data, baseName, width, height, outFolder)

# ----------------------------------------------------------------
# Rebuild from image files (sequence input)
# ----------------------------------------------------------------
proc rebuildMap*(imageFiles: seq[string]): seq[byte] =
  var outData = newSeq[byte]()

  if imageFiles.len == 0:
    return outData

  # Single-image fallback
  if imageFiles.len == 1 and not fileExists(imageFiles[0].splitFile[1].split(".")[^2] & ".1.png"):
    let img = readImage(imageFiles[0])
    var rawBytes = newSeq[byte](img.width * img.height * 4)
    var idx = 0
    for y in 0..<img.height:
      for x in 0..<img.width:
        let c = img.data[img.width * y + x]
        rawBytes[idx]   = byte(c.r); idx.inc()
        rawBytes[idx]   = byte(c.g); idx.inc()
        rawBytes[idx]   = byte(c.b); idx.inc()
        rawBytes[idx]   = byte(c.a); idx.inc()
    let b64 = encode(rawBytes)
    for c in b64: outData.add(byte(c))

  else:
    # Multi-map rebuild
    for imgFile in imageFiles:
      if not fileExists(imgFile):
        continue
      echo "Reading ", imgFile / ""
      let img = readImage(imgFile)
      var rawBytes = newSeq[byte](img.width * img.height * 4)
      var idx = 0
      for y in 0..<img.height:
        for x in 0..<img.width:
          let c = img.data[img.width * y + x]
          rawBytes[idx]   = byte(c.r); idx.inc()
          rawBytes[idx]   = byte(c.g); idx.inc()
          rawBytes[idx]   = byte(c.b); idx.inc()
          rawBytes[idx]   = byte(c.a); idx.inc()
      let b64 = encode(rawBytes)
      outData.add(byte('2'))
      outData.add(byte(0))
      for c in b64: outData.add(byte(c))
      outData.add(byte(0))

  return outData

# ----------------------------------------------------------------
# Rebuild to file, optional folder
# ----------------------------------------------------------------
proc rebuildMapFile*(basename: string, folder: string = "") =
  var imageFiles: seq[string] = @[]
  if fileExists(folder / fmt"{basename}.1.png"):
    # Collect multi-map files starting from 1
    var mapIndex = 1
    while true:
      let imgFile = folder / fmt"{basename}.{mapIndex}.png"
      if not fileExists(imgFile):
        break
      imageFiles.add(imgFile)
      mapIndex += 1
  elif fileExists(folder / fmt"{basename}.png"):
    imageFiles.add(folder / fmt"{basename}.png")
  else:
    echo "No image files found for base: ", basename, " in folder: ", folder
    return

  let outData = rebuildMap(imageFiles)
  let outFile = folder / fmt"{basename}.new.dat"
  writeFile(outFile, cast[string](outData))
  echo "Rebuilt map file: ", (if folder.len > 0: outFile else: fmt"{basename}.new.dat")
