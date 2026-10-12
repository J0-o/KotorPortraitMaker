[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Model,
    [string] $Pose,
    [Nullable[int]] $Frame,
    [Nullable[double]] $CameraAngle,
    [Nullable[double]] $CameraRollDegrees,
    [Nullable[double]] $LensShiftY,
    [Nullable[double]] $OrthographicScale,
    [ValidateSet("single", "alignment_set", "alignment_five", "alignment_k1")] [string] $OutputMode,
    [string] $PortraitName,
    [ValidateSet(128, 256, 512)] [Nullable[int]] $Size,
    [string] $BodyModel,
    [string] $BodyTexture,
    [ValidateRange(0.1, 1.0)] [double] $BodyBrightness = 0.5,
    [ValidateRange(0.0, 10000.0)] [double] $FrontLightPower = 10.0,
    [ValidatePattern("^#[0-9A-Fa-f]{6}$")] [string] $WorldColor,
    [hashtable] $BackgroundGradients = @{},
    [string] $AnimationModel,
    [switch] $EnableGoodPortraits,
    [switch] $RegenerateIntermediateTexturesOnly,
    [switch] $Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$applicationRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$gameFilesDirectory = Join-Path $applicationRoot "game_files"
$settingsPath = Join-Path $applicationRoot "settings.json"
$k1PoseData = Join-Path $PSScriptRoot "data\k1_portrait_poses.csv"
$k2PoseData = Join-Path $PSScriptRoot "data\portrait_poses.csv"
$knownModelsPath = Join-Path $PSScriptRoot "data\known_models.json"
$registryScript = Join-Path $PSScriptRoot "Read-KnownModelRegistry.ps1"
$modelGameScript = Join-Path $PSScriptRoot "Get-KotorModelGame.ps1"
$playerDriver = Join-Path $PSScriptRoot "render_player_head.py"
$fullModelDriver = Join-Path $PSScriptRoot "render_full_model.py"
$importScript = Join-Path $PSScriptRoot "import_kotor_head.py"
$renderScript = Join-Path $PSScriptRoot "render_portrait.py"
$postProcessScript = Join-Path $PSScriptRoot "Post-Process-Portrait.ps1"
$magick = Join-Path $applicationRoot "tools\imagemagick\magick.exe"
$rendersRoot = Join-Path $applicationRoot "renders"
$tempRoot = Join-Path $applicationRoot "temp\imagemagick"
$portraitsRoot = Join-Path $applicationRoot "portraits"
$logsRoot = Join-Path $applicationRoot "logs"

function Require-File {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file does not exist: $Path"
    }
}

function Resolve-ApplicationFile {
    param([Parameter(Mandatory)] [string] $RelativePath)

    if ([IO.Path]::IsPathRooted($RelativePath)) {
        throw "Known-model paths must be relative to the application: $RelativePath"
    }
    $resolved = [IO.Path]::GetFullPath((Join-Path $applicationRoot $RelativePath))
    $rootPrefix = $applicationRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Known-model path leaves the application directory: $RelativePath"
    }
    Require-File $resolved
    return $resolved
}

function Get-GameFileIndex {
    $index = @{}
    foreach ($file in Get-ChildItem -LiteralPath $gameFilesDirectory -File) {
        $key = $file.Name.ToLowerInvariant()
        if ($index.ContainsKey($key)) {
            throw "Case-insensitive filename collision: $($index[$key].Name), $($file.Name)"
        }
        $index[$key] = $file
    }
    return $index
}

function Write-RunLog {
    param([Parameter(Mandatory)] [string] $Message)

    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    Write-Host $entry
}

foreach ($required in @($settingsPath, $knownModelsPath, $registryScript, $modelGameScript, $k1PoseData, $k2PoseData, $renderScript, $postProcessScript, $magick)) {
    Require-File $required
}
. $registryScript
. $modelGameScript
if (-not (Test-Path -LiteralPath $gameFilesDirectory -PathType Container)) {
    throw "Game-files directory does not exist: $gameFilesDirectory"
}

$modelPath = [IO.Path]::GetFullPath($Model)
Require-File $modelPath
$modelDirectory = [IO.Path]::GetDirectoryName($modelPath).TrimEnd('\', '/')
$expectedModelDirectory = [IO.Path]::GetFullPath($gameFilesDirectory).TrimEnd('\', '/')
if ($modelDirectory -ne $expectedModelDirectory) {
    throw "The selected model must be in the top level of $gameFilesDirectory"
}
if ([IO.Path]::GetExtension($modelPath) -ine ".mdl") {
    throw "The selected model is not an MDL file: $modelPath"
}

$fileIndex = Get-GameFileIndex
$modelBase = [IO.Path]::GetFileNameWithoutExtension($modelPath)
$modelGame = Get-KotorModelGame $modelPath
$poseData = if ($modelGame -eq "k1") { $k1PoseData } else { $k2PoseData }
$mdxKey = ($modelBase + ".mdx").ToLowerInvariant()
if (-not $fileIndex.ContainsKey($mdxKey)) {
    throw "Companion MDX is missing: $modelBase.mdx"
}

$knownModels = Read-KnownModelRegistry $knownModelsPath
$modelProfile = @($knownModels.models | Where-Object {
    [string] $_.game -eq $modelGame -and [string] $_.model -ieq $modelBase
}) |
    Select-Object -First 1
$genericPlayerProfile = @($knownModels.fallback_profiles | Where-Object {
    [string] $_.game -eq $modelGame -and [string] $_.fallback_type -eq "player_head"
}) | Select-Object -First 1
$profileName = $modelBase
if ($null -eq $modelProfile) {
    if (Test-KotorModelDependencyName $modelBase) {
        throw "$modelBase is a body or animation dependency, not a selectable portrait subject."
    }
    elseif ($modelBase -match [string] $genericPlayerProfile.model_pattern) {
        $modelProfile = $genericPlayerProfile
        $profileName = "$($modelGame)_player_head_fallback"
    }
    else {
        $modelProfile = @($knownModels.fallback_profiles | Where-Object {
            [string] $_.game -eq $modelGame -and [string] $_.fallback_type -eq "full_model"
        }) | Select-Object -First 1
        $profileName = "$($modelGame)_full_model_fallback"
    }
}
if ($null -eq $modelProfile) {
    throw "No known or generic model profile is available for $modelBase."
}

$workflow = [string] $modelProfile.workflow
if ($workflow -notin @("full_model", "player_head")) {
    throw "Invalid workflow '$workflow' for $modelBase in $knownModelsPath"
}
$scenePath = Resolve-ApplicationFile ([string] $modelProfile.scene)
$prepareScript = Resolve-ApplicationFile ([string] $modelProfile.preparation_script)
$driverScript = if ($workflow -eq "player_head") { $playerDriver } else { $fullModelDriver }

$poseWasProvided = $PSBoundParameters.ContainsKey("Pose")
$frameWasProvided = $PSBoundParameters.ContainsKey("Frame")
$cameraWasProvided = $PSBoundParameters.ContainsKey("CameraAngle")
$cameraRollWasProvided = $PSBoundParameters.ContainsKey("CameraRollDegrees")
$lensShiftWasProvided = $PSBoundParameters.ContainsKey("LensShiftY")
$orthographicScaleWasProvided = $PSBoundParameters.ContainsKey("OrthographicScale")
$frontLightWasProvided = $PSBoundParameters.ContainsKey("FrontLightPower")
if (-not $poseWasProvided) {
    $Pose = [string] $modelProfile.pose
}
if ([string]::IsNullOrWhiteSpace($Pose)) {
    throw "Animation/pose is missing for $modelBase in $knownModelsPath"
}
if (-not $frameWasProvided -and -not $poseWasProvided) {
    $Frame = [int] $modelProfile.frame
}
if ($null -ne $Frame -and $Frame -lt 0) {
    throw "Frame cannot be negative: $Frame"
}
if (-not $cameraWasProvided) {
    $CameraAngle = [double] $modelProfile.camera_x
}
if (-not $cameraRollWasProvided) {
    $CameraRollDegrees = [double] $modelProfile.camera_roll_degrees
}
if ($CameraRollDegrees -lt -180.0 -or $CameraRollDegrees -gt 180.0) {
    throw "Camera roll must be from -180 through 180 degrees: $CameraRollDegrees"
}
if (-not $lensShiftWasProvided) {
    $LensShiftY = [double] $modelProfile.lens_shift_y
}
if ($LensShiftY -lt -10.0 -or $LensShiftY -gt 10.0) {
    throw "Lens shift Y must be from -10.0 through 10.0: $LensShiftY"
}
if (-not $orthographicScaleWasProvided) {
    $OrthographicScale = [double] $modelProfile.orthographic_scale
}
if ($OrthographicScale -le 0.0 -or $OrthographicScale -gt 1000.0) {
    throw "Orthographic scale must be greater than 0 and no more than 1000: $OrthographicScale"
}
if (-not $frontLightWasProvided) {
    $frontLightProperty = $modelProfile.PSObject.Properties["front_light_power"]
    $FrontLightPower = if ($null -eq $frontLightProperty) {
        10.0
    }
    else {
        [double] $frontLightProperty.Value
    }
}
if ($FrontLightPower -lt 0.0 -or $FrontLightPower -gt 10000.0) {
    throw "Front light power must be from 0 through 10000: $FrontLightPower"
}
if (-not $PSBoundParameters.ContainsKey("WorldColor")) {
    $worldColorProperty = $modelProfile.PSObject.Properties["world_color"]
    if ($null -ne $worldColorProperty) {
        $WorldColor = [string] $worldColorProperty.Value
    }
}
if (-not [string]::IsNullOrWhiteSpace($WorldColor) -and $WorldColor -notmatch "^#[0-9A-Fa-f]{6}$") {
    throw "WorldColor must use #RRGGBB format: $WorldColor"
}
if (-not $PSBoundParameters.ContainsKey("OutputMode")) {
    $OutputMode = [string] $modelProfile.output_mode
}
if ([bool] $modelProfile.lock_output_mode) {
    $OutputMode = "single"
}
if ($OutputMode -notin @("single", "alignment_set", "alignment_five", "alignment_k1")) {
    throw "Invalid output_mode '$OutputMode' for $modelBase in $knownModelsPath"
}
if ($OutputMode -in @("alignment_five", "alignment_k1") -and $workflow -ne "player_head") {
    throw "Five-portrait modes only apply to player-head workflows."
}
if ($OutputMode -eq "alignment_k1" -and $modelGame -ne "k1") {
    throw "The KOTOR alignment mode only applies to KOTOR models."
}
if ($EnableGoodPortraits -and $OutputMode -eq "single") {
    throw "Good portraits require an alignment output mode."
}
if ($RegenerateIntermediateTexturesOnly -and $OutputMode -ne "alignment_five") {
    throw "D0/D3 regeneration requires the extended alignment output mode."
}
if (-not $PSBoundParameters.ContainsKey("Size")) {
    $Size = [int] $modelProfile.size
}
if ($Size -notin @(128, 256, 512)) {
    throw "Invalid size '$Size' for $modelBase in $knownModelsPath"
}
if (-not $PSBoundParameters.ContainsKey("AnimationModel")) {
    $AnimationModel = [string] $modelProfile.animation_model
    if ($modelGame -eq "k1" -and
        $fileIndex.ContainsKey("s_female03.mdl") -and
        $fileIndex.ContainsKey("s_female03.mdx")) {
        $AnimationModel = "S_Female03"
    }
}
if ([string]::IsNullOrWhiteSpace($PortraitName)) {
    $PortraitName = [string] $modelProfile.portrait_name
    if ($PortraitName -eq "model_basename") {
        $PortraitName = Get-DefaultPortraitName $modelBase $modelGame
    }
}

if ($workflow -eq "player_head") {
    if ([string]::IsNullOrWhiteSpace($AnimationModel)) {
        throw "animation_model is required for PF/PM profile $modelBase"
    }

    if ([string]::IsNullOrWhiteSpace($BodyModel)) {
        $bodyProperty = $modelProfile.PSObject.Properties["body_model"]
        if ($null -ne $bodyProperty -and
            -not [string]::IsNullOrWhiteSpace([string] $bodyProperty.Value)) {
            $BodyModel = [string] $bodyProperty.Value
        }
        elseif ($modelBase -match "^(?i:pmh)") {
            $BodyModel = "N_CommM"
        }
        elseif ($modelBase -match "^(?i:pfh)") {
            $BodyModel = "N_CommF"
        }
        elseif ($modelBase.EndsWith("H", [StringComparison]::OrdinalIgnoreCase)) {
            $BodyModel = $modelBase.Substring(0, $modelBase.Length - 1) + "BB"
        }
        else {
            throw "Cannot infer a body for $modelBase; provide -BodyModel."
        }
    }
    $dependencies = @($BodyModel)
    if ($AnimationModel -ne "none") {
        $dependencies += $AnimationModel
    }
    foreach ($dependency in $dependencies) {
        foreach ($extension in @(".mdl", ".mdx")) {
            $key = ($dependency + $extension).ToLowerInvariant()
            if (-not $fileIndex.ContainsKey($key)) {
                throw "Required player-head dependency is missing: $dependency$extension"
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($BodyTexture)) {
        $textureMatches = @(
            foreach ($extension in @(".tga", ".png")) {
                $key = ($BodyTexture + $extension).ToLowerInvariant()
                if ($fileIndex.ContainsKey($key)) {
                    $fileIndex[$key]
                }
            }
        )
        if ($textureMatches.Count -eq 0) {
            throw "Body texture is missing: $BodyTexture.tga or $BodyTexture.png"
        }
        if ($textureMatches.Count -gt 1) {
            throw "Body texture is ambiguous; keep only one format for $BodyTexture in game_files."
        }
        $BodyTexture = $textureMatches[0].BaseName
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($BodyTexture)) {
    throw "BodyTexture only applies to player-head workflows."
}
elseif ($PSBoundParameters.ContainsKey("BodyBrightness")) {
    throw "BodyBrightness only applies to player-head workflows."
}

foreach ($required in @($driverScript, $prepareScript)) {
    Require-File $required
}

$maxNameLength = if ($OutputMode -eq "single") { 13 } else { 11 }
if ($PortraitName.Length -gt $maxNameLength -and [string] $modelProfile.portrait_name -eq "model_basename") {
    $PortraitName = $PortraitName.Substring(0, $maxNameLength)
}
if ($PortraitName -notmatch "^[A-Za-z0-9_]+$") {
    throw "PortraitName may contain only letters, numbers, and underscores."
}
if ($PortraitName.Length -gt $maxNameLength) {
    throw "PortraitName is too long. The maximum for $OutputMode is $maxNameLength characters."
}

$renderStageNames = @(switch ($OutputMode) {
    "single" { @("normal") }
    "alignment_set" { @("normal", "d1", "d2") }
    "alignment_five" { @("normal", "d0", "d1", "d3", "d2") }
    "alignment_k1" { @("normal", "d1", "d2", "d3", "d") }
})
$outputStageNames = @($renderStageNames)
if ($EnableGoodPortraits) {
    $outputStageNames = @("normal", "g1", "g2") + @(
        $renderStageNames | Where-Object { $_ -ne "normal" }
    )
}
$stageSettings = @(
    foreach ($stage in $renderStageNames) {
        $recipe = @($modelProfile.portraits | Where-Object { [string] $_.stage -eq $stage }) |
            Select-Object -First 1
        if ($null -eq $recipe) {
            throw "Portrait settings are missing for $modelBase/$stage in $knownModelsPath"
        }
        $stagePose = if ($poseWasProvided) {
            $Pose
        }
        else {
            [string] $recipe.pose
        }
        $stageFrame = if ($frameWasProvided) {
            $Frame
        }
        elseif ($poseWasProvided) {
            $null
        }
        else {
            [int] $recipe.frame
        }
        $stageCamera = if ($cameraWasProvided) {
            [double] $CameraAngle
        }
        else {
            [double] $recipe.camera_x
        }
        $stageCameraRollDegrees = if ($cameraRollWasProvided) {
            [double] $CameraRollDegrees
        }
        else {
            [double] $recipe.camera_roll_degrees
        }
        $stageLensShiftY = if ($lensShiftWasProvided) { [double] $LensShiftY } else { [double] $recipe.lens_shift_y }
        $stageOrthographicScale = if ($orthographicScaleWasProvided) { [double] $OrthographicScale } else { [double] $recipe.orthographic_scale }
        [object[]] $stageTextureSuffixes = @($recipe.texture_suffixes)
        $stageTextureOverrides = $recipe.texture_overrides
        [object[]] $bodyTextureSuffixes = @($recipe.body_texture_suffixes)
        $bodyTextureOverrides = $recipe.body_texture_overrides
        $bodyBrightnessFactor = [double] $recipe.body_brightness_factor
        $modelBrightnessFactor = if ($recipe.PSObject.Properties.Name -contains "model_brightness_factor") {
            [double] $recipe.model_brightness_factor
        }
        else {
            1.0
        }
        $backgroundTopRight = [string] $recipe.background_top_right
        $backgroundBottomLeft = [string] $recipe.background_bottom_left
        if ($BackgroundGradients.ContainsKey($stage)) {
            $override = $BackgroundGradients[$stage]
            $backgroundTopRight = [string] $override.topRight
            $backgroundBottomLeft = [string] $override.bottomLeft
        }
        foreach ($color in @($backgroundTopRight, $backgroundBottomLeft)) {
            if ($color -notmatch "^#[0-9A-Fa-f]{6}$") {
                throw "Background colors must use #RRGGBB format: $color"
            }
        }
        $stageFrontLightPower = if ($frontLightWasProvided) { [double] $FrontLightPower } else { [double] $recipe.front_light_power }
        if ($stageFrontLightPower -lt 0.0 -or $stageFrontLightPower -gt 10000.0) {
            throw "Front light power must be from 0 through 10000: $stageFrontLightPower"
        }
        [ordered]@{
            stage = $stage
            animation = if (-not $poseWasProvided) {
                [string] $recipe.animation
            }
            else {
                $stagePose
            }
            pose = $stagePose
            frame = $stageFrame
            camera_x = $stageCamera
            camera_roll_degrees = $stageCameraRollDegrees
            lens_shift_y = $stageLensShiftY
            orthographic_scale = $stageOrthographicScale
            texture_suffixes = $stageTextureSuffixes
            texture_overrides = $stageTextureOverrides
            body_texture_stage = [string] $recipe.body_texture_stage
            body_texture_suffixes = $bodyTextureSuffixes
            body_texture_overrides = $bodyTextureOverrides
            body_brightness_factor = $bodyBrightnessFactor
            model_brightness_factor = $modelBrightnessFactor
            front_light_power = $stageFrontLightPower
            background_top_right = $backgroundTopRight.ToUpperInvariant()
            background_bottom_left = $backgroundBottomLeft.ToUpperInvariant()
        }
    }
)

$settings = Get-Content -Raw -LiteralPath $settingsPath -Encoding UTF8 | ConvertFrom-Json
$blenderExecutable = [string] $settings.blender_executable
if ([string]::IsNullOrWhiteSpace($blenderExecutable)) {
    throw "The Blender executable is missing from $settingsPath"
}
Require-File $blenderExecutable

$runId = "{0}-{1}-{2}" -f (
    Get-Date -Format "yyyyMMddTHHmmss"
), $modelBase.ToLowerInvariant(), ([guid]::NewGuid().ToString("N").Substring(0, 8))
$renderDirectory = Join-Path $rendersRoot $runId
$tempDirectory = Join-Path $tempRoot $runId
$portraitDirectory = $portraitsRoot
$logPath = Join-Path $logsRoot ($runId + ".log")

New-Item -ItemType Directory -Path $renderDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null

$stagePlanPath = Join-Path $renderDirectory "stage-plan.json"
ConvertTo-Json -InputObject $stageSettings -Depth 4 | Set-Content -LiteralPath $stagePlanPath -Encoding UTF8
$runManifestPath = Join-Path $renderDirectory "run.json"
$run = [ordered]@{
    schema_version = 5
    run_id = $runId
    status = "rendering"
    profile = $profileName
    game = $modelGame
    workflow = $workflow
    model = [IO.Path]::GetFileName($modelPath)
    scene = [string] $modelProfile.scene
    preparation_script = [string] $modelProfile.preparation_script
    animation_model = $AnimationModel
    body_model = $BodyModel
    body_texture = $BodyTexture
    body_brightness = $BodyBrightness
    front_light_power = $FrontLightPower
    world_color = $WorldColor
    pose = $Pose
    frame = $Frame
    camera_x = $CameraAngle
    camera_roll_degrees = $CameraRollDegrees
    lens_shift_y = $LensShiftY
    orthographic_scale = $OrthographicScale
    output_mode = $OutputMode
    enable_good_portraits = [bool] $EnableGoodPortraits
    portrait_count = $outputStageNames.Count
    portrait_name = $PortraitName
    size = $Size
    regenerate_intermediate_textures_only = [bool] $RegenerateIntermediateTexturesOnly
    output_stages = $outputStageNames
    portraits = $stageSettings
}
$run | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runManifestPath -Encoding UTF8

$blenderArguments = @(
    "--background", $scenePath,
    "--python-exit-code", "1",
    "--python", $driverScript,
    "--",
    "--model", $modelPath,
    "--game-files", $gameFilesDirectory,
    "--render-dir", $renderDirectory,
    "--pose-data", $poseData,
    "--pose", $Pose,
    "--camera-x", $CameraAngle.ToString([Globalization.CultureInfo]::InvariantCulture),
    "--camera-roll-degrees", $CameraRollDegrees.ToString([Globalization.CultureInfo]::InvariantCulture),
    "--lens-shift-y", $LensShiftY.ToString([Globalization.CultureInfo]::InvariantCulture),
    "--orthographic-scale", $OrthographicScale.ToString([Globalization.CultureInfo]::InvariantCulture),
    "--front-light-power", $FrontLightPower.ToString([Globalization.CultureInfo]::InvariantCulture),
    "--size", $Size.ToString([Globalization.CultureInfo]::InvariantCulture),
    "--output-mode", $OutputMode,
    "--stage-plan", $stagePlanPath,
    "--magick", $magick,
    "--render-script", $renderScript
)
if (-not [string]::IsNullOrWhiteSpace($WorldColor)) {
    $blenderArguments += @("--world-color", $WorldColor)
}
if ($RegenerateIntermediateTexturesOnly) {
    $blenderArguments += "--regenerate-intermediate-textures-only"
}
if ($null -ne $Frame) {
    $blenderArguments += @("--frame", $Frame.ToString([Globalization.CultureInfo]::InvariantCulture))
}
if ($workflow -eq "player_head") {
    $blenderArguments += @(
        "--import-script", $importScript,
        "--body-model", $BodyModel,
        "--animation-model", $AnimationModel,
        "--body-brightness", $BodyBrightness.ToString([Globalization.CultureInfo]::InvariantCulture)
    )
    if (-not [string]::IsNullOrWhiteSpace($BodyTexture)) {
        $blenderArguments += @("--body-texture", $BodyTexture)
    }
}
else {
    $blenderArguments += @("--prepare-script", $prepareScript)
}

$operation = if ($RegenerateIntermediateTexturesOnly) {
    "D0/D3 regeneration"
}
else {
    "$workflow render"
}
Write-RunLog "Starting $operation for $modelBase ($OutputMode)."
$savedErrorPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    & $blenderExecutable @blenderArguments 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if ($line -notmatch "^(Fra:|Time:|\s*$)") {
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
            Write-Host $line
        }
    }
    $blenderExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $savedErrorPreference
}
if ($blenderExitCode -ne 0) {
    $run.status = "render_failed"
    $run | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runManifestPath -Encoding UTF8
    throw "Blender failed with exit code $blenderExitCode. See $logPath"
}
if ($RegenerateIntermediateTexturesOnly) {
    $run.status = "complete"
    $run.outputs = @()
    $run | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runManifestPath -Encoding UTF8
    Write-RunLog "D0/D3 regeneration finished for $modelBase."
    return [pscustomobject]@{
        RunId = $runId
        RenderDirectory = $renderDirectory
        PortraitDirectory = $null
        Files = @()
    }
}

foreach ($stage in $renderStageNames) {
    Require-File (Join-Path $renderDirectory ($stage + ".png"))
}

New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $portraitDirectory -Force | Out-Null
$finalFiles = [Collections.Generic.List[string]]::new()
$stagedFiles = [Collections.Generic.List[object]]::new()

foreach ($stage in $outputStageNames) {
    $sourceStage = if ($stage -in @("g1", "g2")) { "normal" } else { $stage }
    $source = Join-Path $renderDirectory ($sourceStage + ".png")
    $suffix = if ($stage -eq "normal") { "" } else { $stage }
    $fileName = "po_" + $PortraitName + $suffix + ".tga"
    $stagedTga = Join-Path $tempDirectory $fileName
    $destination = Join-Path $portraitDirectory $fileName

    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        throw "Final portrait already exists: $destination. Use -Force to replace it."
    }

    $stageSetting = @($stageSettings | Where-Object { [string] $_.stage -eq $stage }) |
        Select-Object -First 1
    if ($null -eq $stageSetting) {
        $stageSetting = @($modelProfile.portraits | Where-Object { [string] $_.stage -eq $stage }) |
            Select-Object -First 1
    }
    if ($null -eq $stageSetting) {
        throw "Portrait output settings are missing for $modelBase/$stage in $knownModelsPath"
    }
    $outputBackgroundTopRight = [string] $stageSetting.background_top_right
    $outputBackgroundBottomLeft = [string] $stageSetting.background_bottom_left
    if ($BackgroundGradients.ContainsKey($stage)) {
        $outputBackgroundTopRight = [string] $BackgroundGradients[$stage].topRight
        $outputBackgroundBottomLeft = [string] $BackgroundGradients[$stage].bottomLeft
    }
    & $postProcessScript -Source $source -Destination $stagedTga `
        -TempDirectory $tempDirectory -Size $Size -ImageMagick $magick -Stage $stage -Game $modelGame `
        -BackgroundTopRight $outputBackgroundTopRight `
        -BackgroundBottomLeft $outputBackgroundBottomLeft
    $stagedFiles.Add([pscustomobject]@{ Source = $stagedTga; Destination = $destination })
}

foreach ($file in $stagedFiles) {
    Move-Item -LiteralPath $file.Source -Destination $file.Destination -Force
    $finalFiles.Add($file.Destination)
}

$run.status = "complete"
$run.outputs = @($finalFiles | ForEach-Object {
    "portraits/$([IO.Path]::GetFileName($_))"
})
$run | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $runManifestPath -Encoding UTF8
Write-RunLog "Created $($finalFiles.Count) final portrait(s) in $portraitDirectory."

$resolvedTemp = [IO.Path]::GetFullPath($tempDirectory)
$resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot) + [IO.Path]::DirectorySeparatorChar
if ($resolvedTemp.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
}
else {
    throw "Refusing to clean unexpected temp path: $resolvedTemp"
}

[pscustomobject]@{
    RunId = $runId
    RenderDirectory = $renderDirectory
    PortraitDirectory = $portraitDirectory
    Files = @($finalFiles)
}
