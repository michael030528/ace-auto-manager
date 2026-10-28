$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$assets = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
$frames = @()
foreach ($size in @(16,24,32,48,64,128,256)) {
    $bmp = New-Object Drawing.Bitmap ($size,$size)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.ScaleTransform(($size/256.0),($size/256.0))
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddBezier(128,12,155,29,193,39,224,44)
    $path.AddLine(224,44,219,125)
    $path.AddBezier(219,125,215,178,174,220,128,244)
    $path.AddBezier(128,244,82,220,41,178,37,125)
    $path.AddLine(37,125,32,44)
    $path.AddBezier(32,44,63,39,101,29,128,12)
    $path.CloseFigure()
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(40,25)),([Drawing.Point]::new(210,230)),([Drawing.Color]::FromArgb(47,157,244)),([Drawing.Color]::FromArgb(29,68,193))
    $g.FillPath($brush,$path)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White),18
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen,79,81,98,98,-48,276)
    $g.DrawLine($pen,128,66,128,122)
    $stream = New-Object IO.MemoryStream
    $bmp.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
    $frames += ,@{Size=$size; Bytes=$stream.ToArray()}
    if ($size -eq 256) { $bmp.Save((Join-Path $assets 'app-icon.png'),[Drawing.Imaging.ImageFormat]::Png) }
    $stream.Dispose(); $pen.Dispose(); $brush.Dispose(); $path.Dispose(); $g.Dispose(); $bmp.Dispose()
}
$file = [IO.File]::Create((Join-Path $assets 'app.ico'))
$writer = New-Object IO.BinaryWriter $file
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$frames.Count)
    $offset = 6 + 16*$frames.Count
    foreach ($frame in $frames) {
        $dimension = if ($frame.Size -eq 256) {0} else {$frame.Size}
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$frame.Bytes.Length); $writer.Write([uint32]$offset)
        $offset += $frame.Bytes.Length
    }
    foreach ($frame in $frames) { $writer.Write([byte[]]$frame.Bytes) }
} finally { $writer.Dispose(); $file.Dispose() }
