' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' A QR code for a short text, for the plex.tv/link sign-in and Settings'
' SUPPORT NOSTALGEX row, as the Apple TV app's QRCodeView draws with Core
' Image (CIQRCodeGenerator, correction level M). A Roku has no generator, and sending the sign-in code to a QR
' service would hand it to a third party, so this encodes it here.
'
' Byte mode at level M, versions 1 to 10 (up to 213 bytes); the link with its
' code needs version 3. After Project Nayuki's QR Code generator (MIT): the
' Reed-Solomon blocks, the function patterns, the zigzag placement and the
' mask chosen by the standard's penalty rules. Checked against a reference
' encoder and decoder in tests/QrTests.brs (tests/gen-qr.mjs).

' Draws `modules` (NxQrMatrix's, or invalid for a white square only) into the
' Group `g`: a white square `side` px across, two light modules of quiet zone
' each side inside it, and one dark rectangle per run. For the sign-in's QR
' code and Settings' SUPPORT NOSTALGEX row; a component calls it.
sub NxQrDraw(g as Object, modules as Dynamic, side as Integer)
    bg = CreateObject("roSGNode", "Rectangle")
    bg.width = side
    bg.height = side
    bg.color = "0xFFFFFFFF"
    g.AppendChild(bg)
    if modules = invalid then return
    size = modules.Count()
    cell = side \ (size + 4)
    origin = (side - cell * size) \ 2
    for row = 0 to size - 1
        line = modules[row]
        cx = 0
        while cx < size
            if line[cx] then
                start = cx
                while cx < size and line[cx]
                    cx = cx + 1
                end while
                r = CreateObject("roSGNode", "Rectangle")
                r.translation = [origin + start * cell, origin + row * cell]
                r.width = (cx - start) * cell
                r.height = cell
                r.color = "0x000000FF"
                g.AppendChild(r)
            else
                cx = cx + 1
            end if
        end while
    end for
end sub

' The modules as rows of Booleans (true is dark), with no quiet zone, or
' invalid when the text doesn't fit version 10. `mask` 0 to 7 forces one;
' -1 picks the one with the lowest penalty.
function NxQrMatrix(text as String, mask = -1 as Integer) as Dynamic
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(text)
    ' Data codewords, error-correction codewords per block, and blocks, at
    ' level M for versions 1 to 10.
    eccPerBlock = [10, 16, 26, 18, 24, 16, 18, 22, 22, 26]
    blocks = [1, 1, 1, 2, 2, 4, 4, 4, 5, 5]
    ver = 0
    for v = 1 to 10
        raw = NxQrRawDataModules(v) \ 8
        dataCodewords = raw - eccPerBlock[v - 1] * blocks[v - 1]
        countBits = 8
        if v >= 10 then countBits = 16
        if 4 + countBits + bytes.Count() * 8 <= dataCodewords * 8 then
            ver = v
            exit for
        end if
    end for
    if ver = 0 then return invalid

    ' The data bits: byte mode, the count, the bytes, a terminator, padding.
    bits = []
    NxQrAppendBits(bits, 4, 4)
    NxQrAppendBits(bits, bytes.Count(), countBits)
    for each b in bytes
        NxQrAppendBits(bits, b, 8)
    end for
    capacity = dataCodewords * 8
    NxQrAppendBits(bits, 0, NxQrMin(4, capacity - bits.Count()))
    NxQrAppendBits(bits, 0, (8 - bits.Count() mod 8) mod 8)
    pad = &hEC
    while bits.Count() < capacity
        NxQrAppendBits(bits, pad, 8)
        if pad = &hEC then pad = &h11 else pad = &hEC
    end while
    data = []
    for i = 0 to bits.Count() - 1 step 8
        v = 0
        for j = 0 to 7
            v = v * 2
            if bits[i + j] then v = v + 1
        end for
        data.Push(v)
    end for

    codewords = NxQrAddEcc(data, ver, eccPerBlock[ver - 1], blocks[ver - 1])
    q = NxQrNew(ver)
    NxQrDrawFunctionPatterns(q)
    NxQrDrawCodewords(q, codewords)

    if mask < 0 then
        best = 0
        bestPenalty = -1
        for k = 0 to 7
            NxQrApplyMask(q, k)
            NxQrDrawFormatBits(q, k)
            p = NxQrPenalty(q)
            if bestPenalty < 0 or p < bestPenalty then
                best = k
                bestPenalty = p
            end if
            NxQrApplyMask(q, k)
        end for
        mask = best
    end if
    NxQrApplyMask(q, mask)
    NxQrDrawFormatBits(q, mask)
    return q.modules
end function

function NxQrRawDataModules(ver as Integer) as Integer
    result = (16 * ver + 128) * ver + 64
    if ver >= 2 then
        numAlign = ver \ 7 + 2
        result = result - ((25 * numAlign - 10) * numAlign - 55)
        if ver >= 7 then result = result - 36
    end if
    return result
end function

sub NxQrAppendBits(bits as Object, value as Integer, count as Integer)
    for i = count - 1 to 0 step -1
        bits.Push(((value >> i) and 1) = 1)
    end for
end sub

function NxQrXor(a as Integer, b as Integer) as Integer
    return (a or b) and not (a and b)
end function

' GF(256) over x^8 + x^4 + x^3 + x^2 + 1, by log tables.
function NxQrGf() as Object
    g = GetGlobalAA()
    if g.nxQrGf <> invalid then return g.nxQrGf
    exp = []
    log = []
    for i = 0 to 255
        log.Push(0)
    end for
    x = 1
    for i = 0 to 511
        exp.Push(x)
        if i < 255 then log[x] = i
        x = x * 2
        if x >= 256 then x = NxQrXor(x, &h11D)
    end for
    g.nxQrGf = { exp: exp, log: log }
    return g.nxQrGf
end function

function NxQrMul(a as Integer, b as Integer, gf as Object) as Integer
    if a = 0 or b = 0 then return 0
    return gf.exp[gf.log[a] + gf.log[b]]
end function

' Splits the data into blocks, adds each block's error correction, and
' interleaves them, as the standard orders them.
function NxQrAddEcc(data as Object, ver as Integer, eccLen as Integer, numBlocks as Integer) as Object
    gf = NxQrGf()
    raw = NxQrRawDataModules(ver) \ 8
    numShort = numBlocks - raw mod numBlocks
    shortLen = raw \ numBlocks
    ' The generator polynomial, highest term dropped.
    divisor = []
    for i = 1 to eccLen - 1
        divisor.Push(0)
    end for
    divisor.Push(1)
    root = 1
    for i = 1 to eccLen
        for j = 0 to eccLen - 1
            divisor[j] = NxQrMul(divisor[j], root, gf)
            if j + 1 < eccLen then divisor[j] = NxQrXor(divisor[j], divisor[j + 1])
        end for
        root = NxQrMul(root, 2, gf)
    end for

    out = []
    k = 0
    for i = 0 to numBlocks - 1
        n = shortLen - eccLen
        if i >= numShort then n = n + 1
        dat = []
        for j = 0 to n - 1
            dat.Push(data[k + j])
        end for
        k = k + n
        remain = []
        for j = 1 to eccLen
            remain.Push(0)
        end for
        for each b in dat
            factor = NxQrXor(b, remain.Shift())
            remain.Push(0)
            for j = 0 to eccLen - 1
                remain[j] = NxQrXor(remain[j], NxQrMul(divisor[j], factor, gf))
            end for
        end for
        ' A short block gets a gap where the long ones have a last data byte.
        if i < numShort then dat.Push(-1)
        dat.Append(remain)
        out.Push(dat)
    end for
    result = []
    for i = 0 to out[0].Count() - 1
        for j = 0 to out.Count() - 1
            if i <> shortLen - eccLen or j >= numShort then result.Push(out[j][i])
        end for
    end for
    return result
end function

function NxQrNew(ver as Integer) as Object
    size = ver * 4 + 17
    modules = []
    isFunction = []
    for y = 0 to size - 1
        row = []
        frow = []
        for x = 0 to size - 1
            row.Push(false)
            frow.Push(false)
        end for
        modules.Push(row)
        isFunction.Push(frow)
    end for
    return { ver: ver, size: size, modules: modules, isFunction: isFunction }
end function

sub NxQrSetFunction(q as Object, x as Integer, y as Integer, dark as Boolean)
    q.modules[y][x] = dark
    q.isFunction[y][x] = true
end sub

sub NxQrDrawFunctionPatterns(q as Object)
    size = q.size
    for i = 0 to size - 1
        NxQrSetFunction(q, 6, i, i mod 2 = 0)
        NxQrSetFunction(q, i, 6, i mod 2 = 0)
    end for
    NxQrDrawFinder(q, 3, 3)
    NxQrDrawFinder(q, size - 4, 3)
    NxQrDrawFinder(q, 3, size - 4)
    centers = NxQrAlignmentPositions(q.ver, size)
    n = centers.Count()
    for i = 0 to n - 1
        for j = 0 to n - 1
            corner = (i = 0 and j = 0) or (i = 0 and j = n - 1) or (i = n - 1 and j = 0)
            if not corner then NxQrDrawAlignment(q, centers[i], centers[j])
        end for
    end for
    NxQrDrawFormatBits(q, 0)
    NxQrDrawVersion(q)
end sub

sub NxQrDrawFinder(q as Object, cx as Integer, cy as Integer)
    for dy = -4 to 4
        for dx = -4 to 4
            dist = NxQrMax(NxQrAbs(dx), NxQrAbs(dy))
            x = cx + dx
            y = cy + dy
            if x >= 0 and x < q.size and y >= 0 and y < q.size then NxQrSetFunction(q, x, y, dist <> 2 and dist <> 4)
        end for
    end for
end sub

sub NxQrDrawAlignment(q as Object, cx as Integer, cy as Integer)
    for dy = -2 to 2
        for dx = -2 to 2
            NxQrSetFunction(q, cx + dx, cy + dy, NxQrMax(NxQrAbs(dx), NxQrAbs(dy)) <> 1)
        end for
    end for
end sub

function NxQrAlignmentPositions(ver as Integer, size as Integer) as Object
    if ver = 1 then return []
    numAlign = ver \ 7 + 2
    stepLen = (ver * 4 + numAlign * 2 + 1) \ (numAlign * 2 - 2) * 2
    result = [6]
    for i = numAlign - 2 to 0 step -1
        result.Push(size - 7 - i * stepLen)
    end for
    return result
end function

sub NxQrDrawFormatBits(q as Object, mask as Integer)
    ' Level M is 0 in the format's two level bits.
    data = mask
    remainder = data
    for i = 1 to 10
        remainder = NxQrXor(remainder * 2, (remainder >> 9) * &h537)
    end for
    bits = NxQrXor(data * 1024 + remainder, &h5412)
    size = q.size
    for i = 0 to 5
        NxQrSetFunction(q, 8, i, NxQrBit(bits, i))
    end for
    NxQrSetFunction(q, 8, 7, NxQrBit(bits, 6))
    NxQrSetFunction(q, 8, 8, NxQrBit(bits, 7))
    NxQrSetFunction(q, 7, 8, NxQrBit(bits, 8))
    for i = 9 to 14
        NxQrSetFunction(q, 14 - i, 8, NxQrBit(bits, i))
    end for
    for i = 0 to 7
        NxQrSetFunction(q, size - 1 - i, 8, NxQrBit(bits, i))
    end for
    for i = 8 to 14
        NxQrSetFunction(q, 8, size - 15 + i, NxQrBit(bits, i))
    end for
    NxQrSetFunction(q, 8, size - 8, true)
end sub

sub NxQrDrawVersion(q as Object)
    if q.ver < 7 then return
    remainder = q.ver
    for i = 1 to 12
        remainder = NxQrXor(remainder * 2, (remainder >> 11) * &h1F25)
    end for
    bits = q.ver * 4096 + remainder
    for i = 0 to 17
        bit = NxQrBit(bits, i)
        a = q.size - 11 + i mod 3
        b = i \ 3
        NxQrSetFunction(q, a, b, bit)
        NxQrSetFunction(q, b, a, bit)
    end for
end sub

function NxQrMin(a as Integer, b as Integer) as Integer
    if a < b then return a
    return b
end function

function NxQrMax(a as Integer, b as Integer) as Integer
    if a > b then return a
    return b
end function

function NxQrAbs(a as Integer) as Integer
    if a < 0 then return -a
    return a
end function

function NxQrBit(x as Integer, i as Integer) as Boolean
    return ((x >> i) and 1) <> 0
end function

' The codewords in the zigzag of two-module columns, right to left, skipping
' the vertical timing column.
sub NxQrDrawCodewords(q as Object, data as Object)
    size = q.size
    total = data.Count() * 8
    i = 0
    right = size - 1
    while right >= 1
        if right = 6 then right = 5
        upward = ((right + 1) and 2) = 0
        for vert = 0 to size - 1
            for j = 0 to 1
                x = right - j
                y = vert
                if upward then y = size - 1 - vert
                if not q.isFunction[y][x] and i < total then
                    q.modules[y][x] = NxQrBit(data[i >> 3], 7 - (i and 7))
                    i = i + 1
                end if
            end for
        end for
        right = right - 2
    end while
end sub

' Applying a mask twice undoes it.
sub NxQrApplyMask(q as Object, mask as Integer)
    for y = 0 to q.size - 1
        row = q.modules[y]
        frow = q.isFunction[y]
        for x = 0 to q.size - 1
            if not frow[x] then
                if mask = 0 then
                    inv = (x + y) mod 2 = 0
                else if mask = 1 then
                    inv = y mod 2 = 0
                else if mask = 2 then
                    inv = x mod 3 = 0
                else if mask = 3 then
                    inv = (x + y) mod 3 = 0
                else if mask = 4 then
                    inv = (x \ 3 + y \ 2) mod 2 = 0
                else if mask = 5 then
                    inv = (x * y) mod 2 + (x * y) mod 3 = 0
                else if mask = 6 then
                    inv = ((x * y) mod 2 + (x * y) mod 3) mod 2 = 0
                else
                    inv = ((x + y) mod 2 + (x * y) mod 3) mod 2 = 0
                end if
                if inv then row[x] = not row[x]
            end if
        end for
    end for
end sub

' The standard's penalty: runs of five or more, 2x2 blocks, finder-like
' patterns, and the dark/light balance.
function NxQrPenalty(q as Object) as Integer
    size = q.size
    result = 0
    for pass = 0 to 1
        for a = 0 to size - 1
            runColor = false
            runLen = 0
            history = [0, 0, 0, 0, 0, 0, 0]
            for b = 0 to size - 1
                if pass = 0 then dark = q.modules[a][b] else dark = q.modules[b][a]
                if dark = runColor then
                    runLen = runLen + 1
                    if runLen = 5 then
                        result = result + 3
                    else if runLen > 5 then
                        result = result + 1
                    end if
                else
                    NxQrHistoryAdd(history, runLen, size)
                    if not runColor then result = result + NxQrFinderCount(history) * 40
                    runColor = dark
                    runLen = 1
                end if
            end for
            if runColor then
                NxQrHistoryAdd(history, runLen, size)
                runLen = 0
            end if
            NxQrHistoryAdd(history, runLen + size, size)
            result = result + NxQrFinderCount(history) * 40
        end for
    end for
    darkCount = 0
    for y = 0 to size - 1
        for x = 0 to size - 1
            c = q.modules[y][x]
            if c then darkCount = darkCount + 1
            if x < size - 1 and y < size - 1 then
                if c = q.modules[y][x + 1] and c = q.modules[y + 1][x] and c = q.modules[y + 1][x + 1] then result = result + 3
            end if
        end for
    end for
    total = size * size
    k = (NxQrAbs(darkCount * 20 - total * 10) + total - 1) \ total - 1
    return result + k * 10
end function

sub NxQrHistoryAdd(history as Object, runLen as Integer, size as Integer)
    ' A light border before the first run.
    if history[0] = 0 then runLen = runLen + size
    history.Unshift(runLen)
    history.Pop()
end sub

function NxQrFinderCount(h as Object) as Integer
    n = h[1]
    core = n > 0 and h[2] = n and h[3] = n * 3 and h[4] = n and h[5] = n
    count = 0
    if core and h[0] >= n * 4 and h[6] >= n then count = count + 1
    if core and h[6] >= n * 4 and h[0] >= n then count = count + 1
    return count
end function
