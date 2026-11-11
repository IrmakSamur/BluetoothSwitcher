<#
.SYNOPSIS
    Draws the BluetoothSwitcher application icon and writes it as a multi-size .ico.

.DESCRIPTION
    The icon is drawn in code so it can be regenerated and reviewed: a rounded blue
    tile with a white Bluetooth-style rune. Output:
    src\BluetoothSwitcher.App\Assets\AppIcon.ico (16 to 256 px).

    Needs no administrator rights and changes nothing outside the repository.

.PARAMETER PreviewPath
    Optional: also save the 256 px image as a PNG for review.
#>
[CmdletBinding()]
param([string]$PreviewPath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $root 'src\BluetoothSwitcher.App\Assets\AppIcon.ico'
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256

function New-IconBitmap {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # Rounded tile with a vertical blue gradient.
    $inset  = [single]($Size * 0.04)
    $side   = [single]($Size - 2 * $inset)
    $radius = [single]($Size * 0.22)
    $d = 2 * $radius
    $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tile.AddArc($inset, $inset, $d, $d, 180, 90)
    $tile.AddArc($inset + $side - $d, $inset, $d, $d, 270, 90)
    $tile.AddArc($inset + $side - $d, $inset + $side - $d, $d, $d, 0, 90)
    $tile.AddArc($inset, $inset + $side - $d, $d, $d, 90, 90)
    $tile.CloseFigure()
    $rect  = New-Object System.Drawing.RectangleF 0, 0, $Size, $Size
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect,
        ([System.Drawing.Color]::FromArgb(255, 62, 146, 255)),
        ([System.Drawing.Color]::FromArgb(255, 20, 82, 214)), 90.0
    $g.FillPath($brush, $tile)

    # The rune: one continuous stroke through six points.
    $points = @(
        @(0.31, 0.345), @(0.69, 0.655), @(0.50, 0.82),
        @(0.50, 0.18),  @(0.69, 0.345), @(0.31, 0.655)
    ) | ForEach-Object { New-Object System.Drawing.PointF ([single]($_[0] * $Size)), ([single]($_[1] * $Size)) }
    $width = [Math]::Max(1.6, $Size * 0.078)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single]$width)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawLines($pen, [System.Drawing.PointF[]]$points)

    $pen.Dispose(); $brush.Dispose(); $tile.Dispose(); $g.Dispose()
    return $bmp
}

# Classic icon image: BITMAPINFOHEADER, 32-bit BGRA rows bottom-up, then an empty
# 1-bit mask. Every icon reader understands this; PNG entries are only safe at 256 px.
function ConvertTo-IconDib {
    param([System.Drawing.Bitmap]$Bitmap)
    $n = $Bitmap.Width
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $ms
    $w.Write([uint32]40); $w.Write([int32]$n); $w.Write([int32](2 * $n))   # height counts image + mask
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]0)
    $w.Write([uint32](4 * $n * $n)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $n - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $n; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
        }
    }
    $maskRow = New-Object byte[] ([int]([Math]::Ceiling($n / 32.0) * 4))
    for ($y = 0; $y -lt $n; $y++) { $w.Write($maskRow) }
    $w.Flush()
    return ,$ms.ToArray()
}

# Render every size: PNG at 256 px, classic bitmap below that.
$images = foreach ($size in $sizes) {
    $bmp = New-IconBitmap $size
    if ($size -ge 256) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        if ($PreviewPath) { $bmp.Save($PreviewPath, [System.Drawing.Imaging.ImageFormat]::Png) }
    } else {
        $bytes = ConvertTo-IconDib $bmp
    }
    $bmp.Dispose()
    [pscustomobject]@{ Size = $size; Bytes = $bytes }
}

# ICO container: 6-byte header, one 16-byte directory entry per image, then the images.
New-Item -ItemType Directory -Path (Split-Path -Parent $out) -Force | Out-Null
$stream = [System.IO.File]::Create($out)
$writer = New-Object System.IO.BinaryWriter $stream
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($image in $images) {
        $dim = if ($image.Size -ge 256) { 0 } else { $image.Size }   # 0 means 256
        $writer.Write([byte]$dim); $writer.Write([byte]$dim)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$image.Bytes.Length); $writer.Write([uint32]$offset)
        $offset += $image.Bytes.Length
    }
    foreach ($image in $images) { $writer.Write($image.Bytes) }
}
finally { $writer.Dispose(); $stream.Dispose() }

"Wrote $out ({0:n0} bytes, sizes: {1})" -f (Get-Item $out).Length, ($sizes -join ', ')
