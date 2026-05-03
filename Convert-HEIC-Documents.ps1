#requires -version 5.1
[CmdletBinding()]
param(
    [string]$Root,

    [ValidateRange(1, 100)]
    [int]$JpegQuality = 90,

    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $Root = $PSScriptRoot
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $Root = Split-Path -Parent $PSCommandPath
    }
    else {
        $Root = (Get-Location).Path
    }
}

function Format-Size {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-DisplayPath {
    param(
        [string]$BasePath,
        [string]$ChildPath
    )

    if ($ChildPath.StartsWith($BasePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $ChildPath.Substring($BasePath.Length).TrimStart('\', '/')
    }

    return $ChildPath
}

function Save-EncoderToBytes {
    param([System.Windows.Media.Imaging.BitmapEncoder]$Encoder)

    $stream = New-Object System.IO.MemoryStream
    try {
        $Encoder.Save($stream)
        [byte[]]$bytes = $stream.ToArray()
        return ,$bytes
    }
    finally {
        $stream.Dispose()
    }
}

function Get-JpegBytes {
    param(
        [System.Windows.Media.Imaging.BitmapSource]$Frame,
        [int]$Quality
    )

    $encoder = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
    $encoder.QualityLevel = $Quality
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Frame))
    return Save-EncoderToBytes -Encoder $encoder
}

try {
    Add-Type -AssemblyName PresentationCore
}
catch {
    Write-Host 'Failed to load Windows imaging components.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

$resolvedRoot = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')
$sourceFiles = @(
    Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File |
        Where-Object { $_.Extension -match '^\.(heic|heif)$' }
)

if (-not $sourceFiles) {
    Write-Host "No .heic or .heif files were found under $resolvedRoot"
    exit 0
}

$convertedCount = 0
$skippedCount = 0
$failedCount = 0
$deletedSourceCount = 0
$codecHintShown = $false
$convertedFiles = New-Object System.Collections.Generic.List[string]

Write-Host "Scanning $resolvedRoot"
Write-Host "Found $($sourceFiles.Count) HEIC/HEIF file(s)."
Write-Host "Output format: JPG (quality $JpegQuality)"
Write-Host ''

foreach ($file in $sourceFiles) {
    $displayPath = Get-DisplayPath -BasePath $resolvedRoot -ChildPath $file.FullName

    try {
        $inputStream = [System.IO.File]::OpenRead($file.FullName)
        try {
            $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                $inputStream,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            )
            $frame = $decoder.Frames[0]
        }
        finally {
            $inputStream.Dispose()
        }

        $jpgBytes = Get-JpegBytes -Frame $frame -Quality $JpegQuality
        $destinationPath = [System.IO.Path]::ChangeExtension($file.FullName, '.jpg')
        $destinationExists = Test-Path -LiteralPath $destinationPath

        if ($destinationExists -and -not $Overwrite) {
            $skippedCount++
            Write-Host "[SKIP] $displayPath -> $(Split-Path -Leaf $destinationPath) already exists."
            continue
        }

        [System.IO.File]::WriteAllBytes($destinationPath, $jpgBytes)
        $destinationItem = Get-Item -LiteralPath $destinationPath
        $destinationItem.CreationTime = $file.CreationTime
        $destinationItem.LastWriteTime = $file.LastWriteTime
        $destinationItem.LastAccessTime = $file.LastAccessTime

        Remove-Item -LiteralPath $file.FullName -Force

        $convertedCount++
        $deletedSourceCount++
        $convertedFiles.Add($destinationPath) | Out-Null

        $message = "[OK]   $displayPath -> $(Split-Path -Leaf $destinationPath) | JPG | {0} -> {1} | source deleted" -f `
            (Format-Size $file.Length), (Format-Size ([long]$jpgBytes.Length))

        Write-Host $message
    }
    catch {
        $failedCount++
        Write-Host "[FAIL] $displayPath" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red

        if (-not $codecHintShown -and $_.Exception.Message -match 'imaging component|codec|bitmap') {
            Write-Host '       If HEIC decoding fails on this PC, install Microsoft''s HEIF Image Extensions.' -ForegroundColor Yellow
            $codecHintShown = $true
        }
    }
}

Write-Host ''
Write-Host 'Summary'
Write-Host "  Converted: $convertedCount"
Write-Host "  Skipped:   $skippedCount"
Write-Host "  Failed:    $failedCount"
Write-Host "  Source deleted: $deletedSourceCount"

if ($convertedFiles.Count -gt 0) {
    Write-Host ''
    Write-Host 'Converted files'
    foreach ($convertedFile in $convertedFiles) {
        Write-Host "  $convertedFile"
    }
}

if ($failedCount -gt 0) {
    exit 1
}
