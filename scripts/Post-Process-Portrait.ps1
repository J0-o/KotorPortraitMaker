[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Destination,
    [Parameter(Mandatory)] [string] $TempDirectory,
    [Parameter(Mandatory)] [ValidateSet(128, 256, 512)] [int] $Size,
    [Parameter(Mandatory)] [string] $ImageMagick,
    [ValidateSet("normal", "g1", "g2", "d0", "d1", "d2", "d3", "d")] [string] $Stage,
    [ValidateSet("k1", "k2")] [string] $Game = "k2",
    [Parameter(Mandatory)] [ValidatePattern("^#[0-9A-Fa-f]{6}$")] [string] $BackgroundTopRight,
    [Parameter(Mandatory)] [ValidatePattern("^#[0-9A-Fa-f]{6}$")] [string] $BackgroundBottomLeft
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Preserve the model texture colors while adding restrained tonal edits.
# $unsharpMask = "0x0.7+0.7+0.02"
$colorModulation = "100,110,100"
$contrastAdjustment = "0x8"
$highlightMaskLevels = "70%,95%"
$highlightLayerLevels = "0%,92%"
$bloomSettings = @{
    g1 = @{ mask = "65%,90%"; sigma_scale = 0.035; opacity = 0.65 }
    g2 = @{ mask = "55%,88%"; sigma_scale = 0.060; opacity = 0.90 }
}
$smokeEffect = Join-Path $PSScriptRoot "data\smoke_dark.png"

foreach ($required in @($Source, $ImageMagick, $smokeEffect)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required post-processing file does not exist: $required"
    }
}
New-Item -ItemType Directory -Path $TempDirectory -Force | Out-Null

function Get-EffectImageWidth {
    param([Parameter(Mandatory)] [string] $Path)

    $dimensions = (& $ImageMagick identify -format "%w %h" $Path).Trim()
    if ($LASTEXITCODE -ne 0 -or $dimensions -notmatch "^(\d+) (\d+)$") {
        throw "Could not read background-effect dimensions: $Path"
    }
    $width = [int] $Matches[1]
    $height = [int] $Matches[2]
    if ($width -lt 256 -or $height -lt 256) {
        throw "Background-effect images must be at least 256x256: $Path is ${width}x${height}"
    }
    return $width
}

$stageForOffset = if ([string]::IsNullOrWhiteSpace($Stage)) {
    [IO.Path]::GetFileNameWithoutExtension($Source).ToLowerInvariant()
}
else {
    $Stage.ToLowerInvariant()
}
$effectOffsetsPath = Join-Path $TempDirectory ($stageForOffset + "-smoke-offset.json")
if (Test-Path -LiteralPath $effectOffsetsPath -PathType Leaf) {
    $effectOffsets = Get-Content -Raw -LiteralPath $effectOffsetsPath -Encoding UTF8 | ConvertFrom-Json
}
else {
    $smokeWidth = Get-EffectImageWidth $smokeEffect
    $effectOffsets = [ordered]@{
        x = Get-Random -Minimum 0 -Maximum ($smokeWidth - 255)
    }
    $effectOffsets | ConvertTo-Json | Set-Content -LiteralPath $effectOffsetsPath -Encoding UTF8
}

$stage = if ([string]::IsNullOrWhiteSpace($Stage)) {
    [IO.Path]::GetFileNameWithoutExtension($Source).ToLowerInvariant()
}
else {
    $Stage.ToLowerInvariant()
}
$resized = Join-Path $TempDirectory ($stage + "-resized.png")
# $sharpened = Join-Path $TempDirectory ($stage + "-sharpened.png")
$colorAdjusted = Join-Path $TempDirectory ($stage + "-color.png")
$characterAlpha = Join-Path $TempDirectory ($stage + "-alpha.png")
$highlightMask = Join-Path $TempDirectory ($stage + "-highlight-mask.png")
$highlightLayer = Join-Path $TempDirectory ($stage + "-highlight-layer.png")
$highlightComposite = Join-Path $TempDirectory ($stage + "-highlight-composite.png")
$composite = Join-Path $TempDirectory ($stage + "-composite.png")
$bloomMask = Join-Path $TempDirectory ($stage + "-bloom-mask.png")
$bloomLayer = Join-Path $TempDirectory ($stage + "-bloom-layer.png")
$bloomComposite = Join-Path $TempDirectory ($stage + "-bloom-composite.png")
$backgroundGradient = Join-Path $TempDirectory ($stage + "-background-gradient.png")
$smokeMask = Join-Path $TempDirectory ($stage + "-smoke-mask.png")
$darkenedBackground = Join-Path $TempDirectory ($stage + "-background-darkened.png")
$smokeLayer = Join-Path $TempDirectory ($stage + "-smoke-layer.png")
$effectBackground = Join-Path $TempDirectory ($stage + "-background-effects.png")
$backgroundComposite = Join-Path $TempDirectory ($stage + "-background.png")
& $ImageMagick $Source -auto-orient -resize ("{0}x{0}^" -f $Size) `
    -gravity center -background none -extent ("{0}x{0}" -f $Size) $resized
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick resize failed for $stage. Temp files remain in $TempDirectory"
}

# Unsharp masking is disabled because it can harden the transparent silhouette edges.
# & $ImageMagick $resized -unsharp $unsharpMask $sharpened
# if ($LASTEXITCODE -ne 0) {
#     throw "ImageMagick sharpening failed for $stage. Temp files remain in $TempDirectory"
# }

& $ImageMagick $resized -channel RGB -modulate $colorModulation `
    -brightness-contrast $contrastAdjustment +channel $colorAdjusted
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick color adjustment failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $resized -alpha extract $characterAlpha
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick character-alpha extraction failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $colorAdjusted -alpha off -colorspace Gray `
    -level $highlightMaskLevels -blur "0x1" $highlightMask
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick highlight-mask creation failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $colorAdjusted -channel RGB -level $highlightLayerLevels `
    +channel $highlightLayer
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick highlight-layer creation failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $colorAdjusted $highlightLayer $highlightMask `
    -channel RGB -compose Over -composite +channel $highlightComposite
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick highlight compositing failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $highlightComposite $characterAlpha `
    -compose CopyOpacity -composite $composite
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick alpha restoration failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick -size ("{0}x{0}" -f $Size) -define "gradient:angle=45" `
    ("gradient:{0}-{1}" -f $BackgroundBottomLeft, $BackgroundTopRight) `
    -colorspace sRGB -type TrueColor $backgroundGradient
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick background-gradient creation failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $smokeEffect `
    -crop ("256x256+{0}+0" -f [int] $effectOffsets.x) +repage `
    -resize ("{0}x{0}!" -f $Size) -alpha off -colorspace Gray `
    -auto-level -negate $smokeMask
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick smoke-mask creation failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $backgroundGradient -modulate "70,100,100" $darkenedBackground
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick background darkening failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $darkenedBackground $smokeMask -alpha off `
    -compose CopyOpacity -composite $smokeLayer
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick smoke layer creation failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $backgroundGradient $smokeLayer -compose Over -composite `
    $effectBackground
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick background-effect compositing failed for $stage. Temp files remain in $TempDirectory"
}

& $ImageMagick $effectBackground $composite -compose Over -composite `
    -alpha on $backgroundComposite
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick background compositing failed for $stage. Temp files remain in $TempDirectory"
}

$finalImage = $backgroundComposite
if ($bloomSettings.ContainsKey($stage)) {
    $bloom = $bloomSettings[$stage]
    $bloomSigma = ([double] $Size * [double] $bloom.sigma_scale).ToString(
        "0.###", [Globalization.CultureInfo]::InvariantCulture
    )
    & $ImageMagick $backgroundComposite -alpha off -colorspace Gray `
        -level $bloom.mask -blur "0x1" $bloomMask
    if ($LASTEXITCODE -ne 0) {
        throw "ImageMagick final bloom-mask creation failed for $stage. Temp files remain in $TempDirectory"
    }

    & $ImageMagick $backgroundComposite $bloomMask -alpha off `
        -compose CopyOpacity -composite -channel A -evaluate Multiply $bloom.opacity `
        +channel -blur ("0x{0}" -f $bloomSigma) $bloomLayer
    if ($LASTEXITCODE -ne 0) {
        throw "ImageMagick final bloom-layer creation failed for $stage. Temp files remain in $TempDirectory"
    }

    & $ImageMagick $backgroundComposite $bloomLayer -compose Screen -composite $bloomComposite
    if ($LASTEXITCODE -ne 0) {
        throw "ImageMagick final bloom compositing failed for $stage. Temp files remain in $TempDirectory"
    }
    $finalImage = $bloomComposite
}

& $ImageMagick $finalImage -colorspace sRGB -alpha on -type TrueColorAlpha `
    -flip -orient BottomLeft -compress None `
    -define "tga:bits-per-pixel=32" $Destination
if ($LASTEXITCODE -ne 0) {
    throw "ImageMagick TGA conversion failed for $stage. Temp files remain in $TempDirectory"
}

$identity = (& $ImageMagick identify -format "%wx%h|%[channels]" $Destination).Trim()
$tgaHeader = [System.IO.File]::ReadAllBytes($Destination)
if ($LASTEXITCODE -ne 0 -or
    $identity -notmatch ("^{0}x{0}\|srgba [^|]+$" -f $Size) -or
    $tgaHeader.Length -lt 18 -or $tgaHeader[2] -ne 2 -or $tgaHeader[16] -ne 32) {
    throw "Final image validation failed for $Destination ($identity; expected uncompressed 32-bit true-color TGA)"
}
