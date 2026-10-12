$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Locate game models and the separate script that will consume selections.
$gameFilesDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\game_files"))
$k1PoseShortlist = Join-Path $PSScriptRoot "data\k1_portrait_poses.csv"
$k2PoseShortlist = Join-Path $PSScriptRoot "data\portrait_poses.csv"
$knownModelsPath = Join-Path $PSScriptRoot "data\known_models.json"
$modelGameScript = Join-Path $PSScriptRoot "Get-KotorModelGame.ps1"
$generateScript = Join-Path $PSScriptRoot "Generate-Portrait.ps1"
$registryScript = Join-Path $PSScriptRoot "Read-KnownModelRegistry.ps1"

. $registryScript
$knownModels = Read-KnownModelRegistry $knownModelsPath
. $modelGameScript
$genericProfile = @($knownModels.fallback_profiles | Where-Object {
    [string] $_.game -eq "k2" -and [string] $_.fallback_type -eq "player_head"
}) | Select-Object -First 1

# Keep the current selections in memory while the menu is open.
$selectedModel = $null
$selectedPose = [pscustomobject]@{
    Value = [string] $genericProfile.pose
    Frame = [int] $genericProfile.frame
    Label = "$($genericProfile.animation), frame $($genericProfile.frame)"
}
$selectedCameraAngle = ([double] $genericProfile.camera_x).ToString([Globalization.CultureInfo]::InvariantCulture)
$selectedCameraRollDegrees = ([double] $genericProfile.camera_roll_degrees).ToString([Globalization.CultureInfo]::InvariantCulture)
$selectedLensShiftY = ([double] $genericProfile.lens_shift_y).ToString([Globalization.CultureInfo]::InvariantCulture)
$selectedOrthographicScale = ([double] $genericProfile.orthographic_scale).ToString([Globalization.CultureInfo]::InvariantCulture)
$selectedOutputMode = [string] $genericProfile.output_mode
$selectedGoodPortraits = $false
$selectedPortraitName = $null
$selectedSize = [int] $genericProfile.size
$selectedAnimationModel = [string] $genericProfile.animation_model
$selectedBodyModel = $null
$selectedBodyTexture = $null
$selectedBodyBrightness = 0.5
$genericFrontLightProperty = $genericProfile.PSObject.Properties["front_light_power"]
$selectedFrontLightPower = if ($null -eq $genericFrontLightProperty) { 10.0 } else { [double] $genericFrontLightProperty.Value }
$selectedWorldColor = $null
$selectedBackgroundGradients = @{}
$poseOverride = $false
$cameraOverride = $false
$cameraRollOverride = $false
$lensShiftOverride = $false
$orthographicScaleOverride = $false
$frontLightOverride = $false
$message = "Select a model, then generate or adjust the defaults."

# Display a readable value for a selected or unset option.
function Format-Selection {
    param([AllowNull()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "Not selected"
    }
    return $Value
}

function Format-WorldColor {
    if ([string]::IsNullOrWhiteSpace($selectedWorldColor)) {
        return "Scene default"
    }
    return $selectedWorldColor
}

function Format-BackgroundGradients {
    if ($selectedBackgroundGradients.Count -eq 0) {
        return "Metadata defaults"
    }
    return (@($selectedBackgroundGradients.Keys | Sort-Object | ForEach-Object {
        $gradient = $selectedBackgroundGradients[$_]
        "$_=$($gradient.topRight)/$($gradient.bottomLeft)"
    }) -join ", ")
}

# Display a model path relative to the game_files directory.
function Format-ModelSelection {
    param([AllowNull()] $Model)

    if ($null -eq $Model) {
        return "Not selected"
    }
    return "$($Model.Name) - $($Model.DisplayName) [$($Model.Workflow)]"
}

function Test-PortraitOutputExists {
    param(
        [Parameter(Mandatory)] [string] $PortraitsRoot,
        [Parameter(Mandatory)] [string] $PortraitName,
        [Parameter(Mandatory)] [string] $OutputMode,
        [bool] $EnableGoodPortraits = $false
    )

    $suffixes = @("")
    switch ($OutputMode) {
        "single" {}
        "alignment_set" { $suffixes += @("d1", "d2") }
        "alignment_five" { $suffixes += @("d0", "d1", "d3", "d2") }
        "alignment_k1" { $suffixes += @("d1", "d2", "d3", "d") }
        default { throw "Unknown portrait output mode: $OutputMode" }
    }
    if ($EnableGoodPortraits) {
        $suffixes += @("g1", "g2")
    }
    foreach ($suffix in $suffixes) {
        $fileName = "po_" + $PortraitName + $suffix + ".tga"
        if (Test-Path -LiteralPath (Join-Path $PortraitsRoot $fileName) -PathType Leaf) {
            return $true
        }
    }
    return $false
}

function Get-SupportedModels {
    $script:knownModels = Read-KnownModelRegistry $knownModelsPath
    $models = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $gameFilesDirectory -File -Filter "*.mdl") {
        $modelGame = Get-KotorModelGame $file.FullName
        $profile = @($knownModels.models | Where-Object {
            [string] $_.game -eq $modelGame -and [string] $_.model -ieq $file.BaseName
        }) |
            Select-Object -First 1
        $genericPlayerProfile = @($knownModels.fallback_profiles | Where-Object {
            [string] $_.game -eq $modelGame -and [string] $_.fallback_type -eq "player_head"
        }) | Select-Object -First 1
        if ($null -eq $profile) {
            if (Test-KotorModelDependencyName $file.BaseName) {
                continue
            }
            elseif ($file.BaseName -match [string] $genericPlayerProfile.model_pattern) {
                $profile = $genericPlayerProfile
            }
            else {
                $profile = @($knownModels.fallback_profiles | Where-Object {
                    [string] $_.game -eq $modelGame -and [string] $_.fallback_type -eq "full_model"
                }) | Select-Object -First 1
            }
        }
        if ($null -ne $profile) {
            $models.Add([pscustomobject]@{
                Name = $file.Name
                FullName = $file.FullName
                DisplayName = [string] $profile.display_name
                Game = $modelGame
                Workflow = [string] $profile.workflow
                Profile = $profile
            })
        }
    }
    return @($models | Sort-Object Game, Name)
}

function Get-DefaultBodyModel {
    param(
        [Parameter(Mandatory)] [string] $ModelName,
        [Parameter(Mandatory)] $Profile
    )

    $bodyProperty = $Profile.PSObject.Properties["body_model"]
    if ($null -ne $bodyProperty -and -not [string]::IsNullOrWhiteSpace([string] $bodyProperty.Value)) {
        return [string] $bodyProperty.Value
    }
    if ($ModelName -match "^(?i:pmh)") {
        return "N_CommM"
    }
    if ($ModelName -match "^(?i:pfh)") {
        return "N_CommF"
    }
    if ($ModelName.EndsWith("H", [StringComparison]::OrdinalIgnoreCase)) {
        return $ModelName.Substring(0, $ModelName.Length - 1) + "BB"
    }
    return $null
}

function Get-BodyModels {
    $models = foreach ($file in Get-ChildItem -LiteralPath $gameFilesDirectory -File -Filter "*.mdl") {
        $mdxPath = [IO.Path]::ChangeExtension($file.FullName, ".mdx")
        if ((Test-Path -LiteralPath $mdxPath -PathType Leaf) -and
            ($file.BaseName -match "^(?i:N_|PFB|PMB)" -or $file.BaseName -match "(?i:BB)$")) {
            $file.BaseName
        }
    }
    return @($models | Sort-Object -Unique)
}

function Select-BodyModel {
    param(
        [Parameter(Mandatory)] [array] $Models,
        [Parameter(Mandatory)] [string] $DefaultBody
    )

    Write-Host ""
    Write-Host "Available body models (complete MDL/MDX pairs):"
    Write-Host "  1. Automatic default ($DefaultBody)"
    for ($index = 0; $index -lt $Models.Count; $index++) {
        Write-Host "  $($index + 2). $($Models[$index])"
    }
    Write-Host "  0. Cancel"

    while ($true) {
        $answer = Read-Host "Choose a body model"
        $selection = 0
        if ([int]::TryParse($answer, [ref] $selection) -and
            $selection -ge 0 -and $selection -le ($Models.Count + 1)) {
            if ($selection -eq 0) {
                return $null
            }
            if ($selection -eq 1) {
                return $DefaultBody
            }
            return [string] $Models[$selection - 2]
        }
        Write-Host "Invalid selection." -ForegroundColor Yellow
    }
}

function Select-BodyTexture {
    Write-Host ""
    Write-Host "Enter a TGA/PNG texture ResRef to apply to every textured mesh in the body."
    Write-Host "Enter M to use the texture names stored in the body model, or C to cancel."

    while ($true) {
        $answer = Read-Host "Body texture"
        if ($answer -ieq "c") {
            return "__CANCEL__"
        }
        if ($answer -ieq "m" -or [string]::IsNullOrWhiteSpace($answer)) {
            return ""
        }
        $textureName = [IO.Path]::GetFileNameWithoutExtension($answer.Trim())
        if ($textureName -notmatch "^[A-Za-z0-9_]+$") {
            Write-Host "Texture names may contain only letters, numbers, and underscores." -ForegroundColor Yellow
            continue
        }
        $match = Get-ChildItem -LiteralPath $gameFilesDirectory -File | Where-Object {
            $_.Extension -in @(".tga", ".png") -and $_.BaseName -ieq $textureName
        } | Select-Object -First 1
        if ($null -eq $match) {
            Write-Host "No matching TGA or PNG exists in game_files." -ForegroundColor Yellow
            continue
        }
        return $match.BaseName
    }
}

function Select-BodyBrightness {
    Write-Host ""
    Write-Host "0.5 is the default; 1.0 keeps the imported material unchanged."
    Write-Host "Enter C to cancel."
    while ($true) {
        $answer = Read-Host "Body brightness (0.10 through 1.00)"
        if ($answer -ieq "c") {
            return $null
        }
        $value = 0.0
        if ([double]::TryParse(
            $answer,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref] $value
        ) -and $value -ge 0.1 -and $value -le 1.0) {
            return $value
        }
        Write-Host "Enter a number from 0.10 through 1.00." -ForegroundColor Yellow
    }
}

function Select-FrontLightPower {
    Write-Host ""
    Write-Host "10 is the default front-light power. Enter 0 to turn the front light off."
    Write-Host "Enter C to cancel."
    while ($true) {
        $answer = Read-Host "Front light power (0 through 10000)"
        if ($answer -ieq "c") {
            return $null
        }
        $value = 0.0
        if ([double]::TryParse(
            $answer,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref] $value
        ) -and $value -ge 0.0 -and $value -le 10000.0) {
            return $value
        }
        Write-Host "Enter a number from 0 through 10000." -ForegroundColor Yellow
    }
}

function Select-WorldColor {
    Write-Host ""
    Write-Host "Enter a hex RGB color such as #202020."
    Write-Host "Enter D to use the Blender scene default, or C to cancel."
    while ($true) {
        $answer = Read-Host "World color (#RRGGBB)"
        if ($answer -ieq "c") {
            return "__CANCEL__"
        }
        if ($answer -ieq "d" -or [string]::IsNullOrWhiteSpace($answer)) {
            return ""
        }
        $value = $answer.Trim()
        if ($value -match "^[0-9A-Fa-f]{6}$") {
            $value = "#$value"
        }
        if ($value -match "^#[0-9A-Fa-f]{6}$") {
            return $value.ToUpperInvariant()
        }
        Write-Host "Enter a six-digit hex RGB color such as #202020." -ForegroundColor Yellow
    }
}

function Read-BackgroundColor {
    param([Parameter(Mandatory)] [string] $Prompt)

    while ($true) {
        $answer = Read-Host $Prompt
        if ($answer -ieq "c") {
            return "__CANCEL__"
        }
        $value = $answer.Trim()
        if ($value -match "^[0-9A-Fa-f]{6}$") {
            $value = "#$value"
        }
        if ($value -match "^#[0-9A-Fa-f]{6}$") {
            return $value.ToUpperInvariant()
        }
        Write-Host "Enter a six-digit hex RGB color such as #202040, or C to cancel." -ForegroundColor Yellow
    }
}

function Select-BackgroundGradient {
    [object[]] $stages = @(switch ($selectedOutputMode) {
        "single" { @("normal") }
        "alignment_set" { @("normal", "d1", "d2") }
        "alignment_five" { @("normal", "d0", "d1", "d3", "d2") }
        "alignment_k1" { @("normal", "d1", "d2", "d3", "d") }
    })
    if ($selectedGoodPortraits) {
        $stages += @("g1", "g2")
    }

    Write-Host ""
    Write-Host "Portrait stages:"
    for ($index = 0; $index -lt $stages.Count; $index++) {
        Write-Host "  $($index + 1). $($stages[$index])"
    }
    Write-Host "  0. Cancel"
    while ($true) {
        $answer = Read-Host "Choose a stage"
        $selection = 0
        if ([int]::TryParse($answer, [ref] $selection) -and
            $selection -ge 0 -and $selection -le $stages.Count) {
            if ($selection -eq 0) {
                return $null
            }
            break
        }
        Write-Host "Invalid selection." -ForegroundColor Yellow
    }

    $stage = $stages[$selection - 1]
    Write-Host "Enter D at the first prompt to restore metadata defaults for $stage."
    $topRight = Read-Host "Top-right color (#RRGGBB)"
    if ($topRight -ieq "d") {
        return [pscustomobject]@{ Stage = $stage; Clear = $true }
    }
    if ($topRight -match "^[0-9A-Fa-f]{6}$") {
        $topRight = "#$topRight"
    }
    if ($topRight -notmatch "^#[0-9A-Fa-f]{6}$") {
        Write-Host "Invalid top-right color." -ForegroundColor Yellow
        return $null
    }
    $bottomLeft = Read-BackgroundColor "Bottom-left color (#RRGGBB)"
    if ($bottomLeft -eq "__CANCEL__") {
        return $null
    }
    return [pscustomobject]@{
        Stage = $stage
        Clear = $false
        TopRight = $topRight.ToUpperInvariant()
        BottomLeft = $bottomLeft
    }
}

# Display the selected pose label or its unset state.
function Format-PoseSelection {
    param([AllowNull()] $Pose)

    if ($null -eq $Pose) {
        return "Not selected"
    }
    return $Pose.Label
}

# Ask the user to choose one model from a numbered list.
function Select-Model {
    param([Parameter(Mandatory)] [array] $Models)

    Write-Host ""
    Write-Host "Available models:"
    foreach ($game in @("k1", "k2")) {
        $gameModels = @($Models | Where-Object { $_.Game -eq $game })
        if ($gameModels.Count -eq 0) {
            continue
        }
        $gameLabel = if ($game -eq "k1") { "KOTOR" } else { "KOTOR II" }
        Write-Host "  $gameLabel"
        foreach ($model in $gameModels) {
            $index = [array]::IndexOf($Models, $model)
            Write-Host "    $($index + 1). $(Format-ModelSelection $model)"
        }
    }
    Write-Host "  0. Cancel"

    while ($true) {
        $answer = Read-Host "Choose a model"
        $selection = 0
        if ([int]::TryParse($answer, [ref] $selection) -and
            $selection -ge 0 -and $selection -le $Models.Count) {
            if ($selection -eq 0) {
                return $null
            }
            return $Models[$selection - 1]
        }
        Write-Host "Invalid selection." -ForegroundColor Yellow
    }
}

# Load no_animation, then the CSV poses in review-rank order.
function Get-PoseChoices {
    param([Parameter(Mandatory)] [string] $Path)

    $poses = @(
        [pscustomobject]@{ Value = "no_animation"; Frame = 0; Label = "no_animation, frame 0" }
    )
    $rows = @(Import-Csv -LiteralPath $Path | Sort-Object { [int] $_.review_rank })
    foreach ($row in $rows) {
        $name = $row.facial_label
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = $row.dialog_name
        }
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = $row.animation
        }
        $label = "{0} - {1}, frame {2}" -f $name, $row.animation, $row.clip_frame
        $poses += [pscustomobject]@{
            Value = $row.review_rank
            Frame = [int] $row.timeline_frame
            Label = $label
        }
    }
    return $poses
}

# Ask the user to choose no animation, all poses, or one CSV pose.
function Select-Pose {
    param([Parameter(Mandatory)] [array] $Poses)

    Write-Host ""
    Write-Host "Available poses:"
    for ($index = 0; $index -lt $Poses.Count; $index++) {
        Write-Host "  $($index + 1). $($Poses[$index].Label)"
    }
    Write-Host "  0. Cancel"

    while ($true) {
        $answer = Read-Host "Choose a pose"
        $selection = 0
        if ([int]::TryParse($answer, [ref] $selection) -and
            $selection -ge 0 -and $selection -le $Poses.Count) {
            if ($selection -eq 0) {
                return $null
            }
            return $Poses[$selection - 1]
        }
        Write-Host "Invalid selection." -ForegroundColor Yellow
    }
}

# Ask the user for a custom horizontal camera offset.
function Select-CameraAngle {
    Write-Host ""
    Write-Host "Common camera X offsets range from -0.25 to +0.25."
    Write-Host "Enter C to cancel."

    while ($true) {
        $answer = Read-Host "Camera X offset"
        if ($answer -ieq "c") {
            return $null
        }
        $value = 0.0
        if ([double]::TryParse(
            $answer,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref] $value
        ) -and $value -ge -10.0 -and $value -le 10.0) {
            return $value.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        Write-Host "Enter a number from -10.0 through 10.0." -ForegroundColor Yellow
    }
}

# Ask the user for a clockwise camera roll in degrees.
function Select-CameraRollDegrees {
    Write-Host ""
    Write-Host "Small camera rolls commonly range from -5 to +5 degrees."
    Write-Host "Positive values rotate the portrait clockwise. Enter C to cancel."

    while ($true) {
        $answer = Read-Host "Camera roll (degrees)"
        if ($answer -ieq "c") {
            return $null
        }
        $value = 0.0
        if ([double]::TryParse(
            $answer,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref] $value
        ) -and $value -ge -180.0 -and $value -le 180.0) {
            return $value.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        Write-Host "Enter a number from -180 through 180." -ForegroundColor Yellow
    }
}

# Ask the user for a custom vertical camera lens shift.
function Select-LensShiftY {
    Write-Host ""
    Write-Host "The default vertical lens shift is 0.1."
    Write-Host "Enter C to cancel."

    while ($true) {
        $answer = Read-Host "Lens shift Y"
        if ($answer -ieq "c") {
            return $null
        }
        $value = 0.0
        if ([double]::TryParse(
            $answer,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref] $value
        ) -and $value -ge -10.0 -and $value -le 10.0) {
            return $value.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        Write-Host "Enter a number from -10.0 through 10.0." -ForegroundColor Yellow
    }
}

# Ask the user for a custom orthographic camera scale.
function Select-OrthographicScale {
    Write-Host ""
    Write-Host "The default orthographic scale is 0.28."
    Write-Host "Enter C to cancel."

    while ($true) {
        $answer = Read-Host "Orthographic scale"
        if ($answer -ieq "c") {
            return $null
        }
        $value = 0.0
        if ([double]::TryParse(
            $answer,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref] $value
        ) -and $value -gt 0.0 -and $value -le 1000.0) {
            return $value.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        Write-Host "Enter a number greater than 0 and no more than 1000." -ForegroundColor Yellow
    }
}

function Select-OutputMode {
    while ($true) {
        Write-Host ""
        Write-Host "1. Single normal portrait"
        Write-Host "2. Normal + D1 + D2"
        Write-Host "3. Normal + D0 + D1 + D3 + D2 (generate missing dark blends)"
        Write-Host "4. KOTOR normal + D1 + D2 + D3 + D"
        Write-Host "0. Cancel"
        switch (Read-Host "Choose output mode") {
            "1" { return "single" }
            "2" { return "alignment_set" }
            "3" { return "alignment_five" }
            "4" { return "alignment_k1" }
            "0" { return $null }
            default { Write-Host "Invalid selection." -ForegroundColor Yellow }
        }
    }
}

function Select-PortraitName {
    while ($true) {
        $answer = Read-Host "Portrait name without po_ (letters, numbers, underscore; max 11)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $null
        }
        if ($answer -match "^[A-Za-z0-9_]{1,11}$") {
            return $answer
        }
        Write-Host "Invalid portrait name." -ForegroundColor Yellow
    }
}

function Select-OutputSize {
    while ($true) {
        Write-Host ""
        Write-Host "1. 256x256 (default)"
        Write-Host "2. 512x512 (HD)"
        Write-Host "3. 128x128 (classic)"
        Write-Host "0. Cancel"
        switch (Read-Host "Choose portrait size") {
            "1" { return 256 }
            "2" { return 512 }
            "3" { return 128 }
            "0" { return $null }
            default { Write-Host "Invalid selection." -ForegroundColor Yellow }
        }
    }
}

function Show-ManualSettings {
    $manualMessage = "Choose a setting to override the selected model's defaults."
    while ($true) {
        Clear-Host
        Write-Host "Customize Portraits"
        Write-Host ""
        Write-Host "Model: $(Format-ModelSelection $selectedModel)"
        $goodPortraitsLabel = if ($selectedGoodPortraits) { "Enabled" } else { "Disabled" }
        Write-Host "Output: $(Format-Selection $selectedOutputMode) | $(Format-Selection $selectedPortraitName) | ${selectedSize}x${selectedSize} | Good portraits: $goodPortraitsLabel"
        Write-Host "Pose: $(Format-PoseSelection $selectedPose)"
        Write-Host $manualMessage
        Write-Host ""
        Write-Host "Player-head body"
        Write-Host "1. Select body model (player heads)"
        Write-Host "2. Select body texture (player heads)"
        Write-Host "3. Body brightness (player heads)"
        Write-Host ""
        Write-Host "Pose and framing"
        Write-Host "4. Select pose"
        Write-Host "5. Camera X offset"
        Write-Host "6. Camera roll"
        Write-Host "11. Lens shift Y"
        Write-Host "12. Orthographic scale"
        Write-Host ""
        Write-Host "Output"
        Write-Host "7. Output mode"
        Write-Host "8. Portrait name"
        Write-Host "9. Output size"
        Write-Host "13. Toggle good portraits (G1/G2)"
        Write-Host ""
        Write-Host "Lighting and background"
        Write-Host "10. Front light power"
        Write-Host "14. Blender world color"
        Write-Host "15. Final background colors"
        Write-Host ""
        Write-Host "0. Back to main menu"
        Write-Host ""

        switch (Read-Host "Choose a manual setting") {
            "1" {
                if ($null -eq $selectedModel) {
                    $manualMessage = "Select a player-head model before choosing its body."
                }
                elseif ($selectedModel.Workflow -ne "player_head") {
                    $manualMessage = "Body selection only applies to player-head workflows."
                }
                else {
                    $defaultBody = Get-DefaultBodyModel ([IO.Path]::GetFileNameWithoutExtension($selectedModel.Name)) $selectedModel.Profile
                    $value = Select-BodyModel (Get-BodyModels) $defaultBody
                    if ($null -eq $value) {
                        $manualMessage = "Body model was not changed."
                    }
                    else {
                        $script:selectedBodyModel = $value
                        $manualMessage = "Body model selected: $value."
                    }
                }
            }
            "2" {
                if ($null -eq $selectedModel) {
                    $manualMessage = "Select a player-head model before choosing its body texture."
                }
                elseif ($selectedModel.Workflow -ne "player_head") {
                    $manualMessage = "Body textures only apply to player-head workflows."
                }
                else {
                    $value = Select-BodyTexture
                    if ($value -eq "__CANCEL__") {
                        $manualMessage = "Body texture was not changed."
                    }
                    else {
                        $script:selectedBodyTexture = $value
                        $manualMessage = if ([string]::IsNullOrWhiteSpace($value)) {
                            "The body model's stored texture names will be used."
                        }
                        else {
                            "Body texture selected: $value."
                        }
                    }
                }
            }
            "3" {
                if ($null -eq $selectedModel) {
                    $manualMessage = "Select a player-head model before adjusting body brightness."
                }
                elseif ($selectedModel.Workflow -ne "player_head") {
                    $manualMessage = "Body brightness only applies to player-head workflows."
                }
                else {
                    $value = Select-BodyBrightness
                    if ($null -eq $value) {
                        $manualMessage = "Body brightness was not changed."
                    }
                    else {
                        $script:selectedBodyBrightness = $value
                        $manualMessage = "Body brightness selected: $value."
                    }
                }
            }
            "4" {
                if ($null -eq $selectedModel) {
                    $manualMessage = "Select a model before choosing a pose."
                    continue
                }
                if ($selectedModel.Game -eq "k1" -and $selectedAnimationModel -eq "none") {
                    $manualMessage = "K1 pose selection requires S_Female03.mdl and S_Female03.mdx in game_files."
                    continue
                }
                $poseShortlist = if ($selectedModel.Game -eq "k1") {
                    $k1PoseShortlist
                }
                else {
                    $k2PoseShortlist
                }
                if (-not (Test-Path -LiteralPath $poseShortlist -PathType Leaf)) {
                    $manualMessage = "The pose shortlist CSV was not found."
                }
                else {
                    $value = Select-Pose (Get-PoseChoices $poseShortlist)
                    if ($null -eq $value) {
                        $manualMessage = "Pose was not changed."
                    }
                    else {
                        $script:selectedPose = $value
                        $script:poseOverride = $true
                        $manualMessage = "Pose selected."
                    }
                }
            }
            "5" {
                $value = Select-CameraAngle
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $manualMessage = "Camera angle was not changed."
                }
                else {
                    $script:selectedCameraAngle = $value
                    $script:cameraOverride = $true
                    $manualMessage = "Camera angle selected."
                }
            }
            "6" {
                $value = Select-CameraRollDegrees
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $manualMessage = "Camera roll was not changed."
                }
                else {
                    $script:selectedCameraRollDegrees = $value
                    $script:cameraRollOverride = $true
                    $manualMessage = "Camera roll selected: $value degrees."
                }
            }
            "7" {
                $value = Select-OutputMode
                if ($null -ne $value) {
                    $script:selectedOutputMode = $value
                    if ($value -eq "single") {
                        $script:selectedGoodPortraits = $false
                    }
                    $manualMessage = "Output mode selected."
                }
            }
            "8" {
                $value = Select-PortraitName
                if ($null -ne $value) {
                    $script:selectedPortraitName = $value
                    $manualMessage = "Portrait name selected."
                }
            }
            "9" {
                $value = Select-OutputSize
                if ($null -ne $value) {
                    $script:selectedSize = $value
                    $manualMessage = "Output size selected."
                }
            }
            "10" {
                $value = Select-FrontLightPower
                if ($null -eq $value) {
                    $manualMessage = "Front light power was not changed."
                }
                else {
                    $script:selectedFrontLightPower = $value
                    $script:frontLightOverride = $true
                    $manualMessage = "Front light power selected: $value."
                }
            }
            "11" {
                $value = Select-LensShiftY
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $manualMessage = "Lens shift Y was not changed."
                }
                else {
                    $script:selectedLensShiftY = $value
                    $script:lensShiftOverride = $true
                    $manualMessage = "Lens shift Y selected."
                }
            }
            "12" {
                $value = Select-OrthographicScale
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $manualMessage = "Orthographic scale was not changed."
                }
                else {
                    $script:selectedOrthographicScale = $value
                    $script:orthographicScaleOverride = $true
                    $manualMessage = "Orthographic scale selected."
                }
            }
            "13" {
                if ($selectedOutputMode -eq "single") {
                    $manualMessage = "Good portraits require an alignment output mode."
                }
                else {
                    $script:selectedGoodPortraits = -not $selectedGoodPortraits
                    $state = if ($selectedGoodPortraits) { "enabled" } else { "disabled" }
                    $manualMessage = "Good portraits $state."
                }
            }
            "14" {
                $value = Select-WorldColor
                if ($value -eq "__CANCEL__") {
                    $manualMessage = "World color was not changed."
                }
                else {
                    $script:selectedWorldColor = $value
                    $manualMessage = if ([string]::IsNullOrWhiteSpace($value)) {
                        "The Blender scene's default world color will be used."
                    }
                    else {
                        "World color selected: $value."
                    }
                }
            }
            "15" {
                $value = Select-BackgroundGradient
                if ($null -eq $value) {
                    $manualMessage = "Background colors were not changed."
                }
                elseif ($value.Clear) {
                    $script:selectedBackgroundGradients.Remove([string] $value.Stage)
                    $manualMessage = "Metadata background restored for $($value.Stage)."
                }
                else {
                    $script:selectedBackgroundGradients[[string] $value.Stage] = @{
                        topRight = [string] $value.TopRight
                        bottomLeft = [string] $value.BottomLeft
                    }
                    $manualMessage = "Background colors updated for $($value.Stage)."
                }
            }
            "0" {
                $script:message = "Portrait settings updated. Ready to generate."
                return
            }
            default {
                $manualMessage = "Enter one of the listed option numbers."
            }
        }
    }
}

function Get-AvailableKnownModels {
    $script:knownModels = Read-KnownModelRegistry $knownModelsPath
    $files = @{}
    foreach ($file in Get-ChildItem -LiteralPath $gameFilesDirectory -File) {
        $files[$file.Name.ToLowerInvariant()] = $file
    }

    $available = [Collections.Generic.List[object]]::new()
    foreach ($profile in @($knownModels.models)) {
        $modelName = [string] $profile.model
        $mdlKey = ($modelName + ".mdl").ToLowerInvariant()
        $mdxKey = ($modelName + ".mdx").ToLowerInvariant()
        if ($files.ContainsKey($mdlKey) -and $files.ContainsKey($mdxKey)) {
            $game = Get-KotorModelGame $files[$mdlKey].FullName
            if ($game -eq [string] $profile.game) {
                $available.Add([pscustomobject]@{
                    Model = $modelName
                    ModelPath = $files[$mdlKey].FullName
                    Game = $game
                    Profile = $profile
                })
            }
        }
    }
    return @($available)
}

function Invoke-GenerateAllKnownModels {
    $available = @(Get-AvailableKnownModels)
    Clear-Host
    Write-Host "Generate All Available Known Models"
    Write-Host "Found $($available.Count) known model(s) with exact MDL/MDX pairs."
    if ($available.Count -eq 0) {
        Read-Host "Press Enter to return" | Out-Null
        return
    }

    $answer = Read-Host "Generate all $($available.Count) models? (y/N)"
    if ($answer -notmatch "^(?i:y|yes)$") {
        return
    }
    $replace = (Read-Host "Replace existing portrait sets? (y/N)") -match "^(?i:y|yes)$"
    $applicationRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
    $portraitsRoot = Join-Path $applicationRoot "portraits"
    $completed = 0
    $skipped = 0
    $failures = [Collections.Generic.List[string]]::new()

    for ($index = 0; $index -lt $available.Count; $index++) {
        $entry = $available[$index]
        $portraitName = [string] $entry.Profile.portrait_name
        if ($portraitName -eq "model_basename") {
            $portraitName = Get-DefaultPortraitName $entry.Model $entry.Game
        }
        $outputMode = [string] $entry.Profile.output_mode
        if ((Test-PortraitOutputExists $portraitsRoot $portraitName $outputMode) -and -not $replace) {
            Write-Host "[$($index + 1)/$($available.Count)] Skipped $($entry.Model): output already exists."
            $skipped++
            continue
        }

        Write-Host "[$($index + 1)/$($available.Count)] Generating $($entry.Model)..."
        try {
            & $generateScript -Model $entry.ModelPath -Force:$replace | Out-Host
            $completed++
        }
        catch {
            $failures.Add("$($entry.Model): $($_.Exception.Message)")
            Write-Host "Failed $($entry.Model): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "Batch complete: $completed generated, $skipped skipped, $($failures.Count) failed."
    foreach ($failure in $failures) {
        Write-Host "  $failure" -ForegroundColor Red
    }
    Read-Host "Press Enter to return" | Out-Null
}

function Invoke-RegenerateIntermediateTextures {
    $available = @(
        Get-AvailableKnownModels | Where-Object {
            [string] $_.Profile.output_mode -eq "alignment_five"
        }
    )
    Clear-Host
    Write-Host "Force-Regenerate D0/D3 Textures"
    Write-Host "Found $($available.Count) available model(s) with D-transition profiles."
    Write-Host "Models without D transitions will be skipped."
    if ($available.Count -eq 0) {
        Read-Host "Press Enter to return" | Out-Null
        return
    }

    $answer = Read-Host "Overwrite existing D0/D3 textures for these models? (y/N)"
    if ($answer -notmatch "^(?i:y|yes)$") {
        return
    }

    $completed = 0
    $failures = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $available.Count; $index++) {
        $entry = $available[$index]
        Write-Host "[$($index + 1)/$($available.Count)] Checking $($entry.Model)..."
        try {
            & $generateScript -Model $entry.ModelPath -RegenerateIntermediateTexturesOnly | Out-Host
            $completed++
        }
        catch {
            $failures.Add("$($entry.Model): $($_.Exception.Message)")
            Write-Host "Failed $($entry.Model): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "D0/D3 regeneration complete: $completed checked, $($failures.Count) failed."
    foreach ($failure in $failures) {
        Write-Host "  $failure" -ForegroundColor Red
    }
    Read-Host "Press Enter to return" | Out-Null
}

function Show-MaintenanceMenu {
    while ($true) {
        Clear-Host
        Write-Host "Maintenance"
        Write-Host ""
        Write-Host "1. Generate all available known models"
        Write-Host "2. Force-regenerate D0/D3 textures"
        Write-Host "0. Back to main menu"
        Write-Host ""
        switch (Read-Host "Choose a maintenance task") {
            "1" { Invoke-GenerateAllKnownModels }
            "2" { Invoke-RegenerateIntermediateTextures }
            "0" { return }
            default { }
        }
    }
}

# Keep displaying the menu until the user chooses Exit.
while ($true) {
    Clear-Host

    Write-Host "KOTOR Portrait Maker"
    Write-Host ""
    Write-Host "Model: $(Format-ModelSelection $selectedModel)"
    $goodPortraitsLabel = if ($selectedGoodPortraits) { "Enabled" } else { "Disabled" }
    Write-Host "Output: $(Format-Selection $selectedOutputMode) | $(Format-Selection $selectedPortraitName) | ${selectedSize}x${selectedSize} | Good portraits: $goodPortraitsLabel"
    Write-Host "Pose: $(Format-PoseSelection $selectedPose)"
    Write-Host $message
    Write-Host ""
    Write-Host "1. Select model"

    # Every other setting has a default, so only a model selection is required.
    $canGenerate = $null -ne $selectedModel
    if ($canGenerate) {
        Write-Host "2. Generate portraits"
    }
    else {
        Write-Host "2. Generate portraits (select a model first)" -ForegroundColor DarkGray
    }
    Write-Host "3. Customize portraits"
    Write-Host "4. Maintenance"
    Write-Host "0. Exit"
    Write-Host ""

    $choice = Read-Host "Choose an option"
    switch ($choice) {
        "1" {
            # Build a fresh list so newly added MDL files appear immediately.
            $models = @(Get-SupportedModels)
            if ($models.Count -eq 0) {
                $message = "No MDL files were found in the game_files directory."
            }
            else {
                $value = Select-Model $models
                if ([string]::IsNullOrWhiteSpace($value)) {
                    $message = "Model was not changed."
                }
                else {
                    $selectedModel = $value
                    $profile = $value.Profile
                    $recipes = @($profile.portraits)
                    $recipeLabel = if ($recipes.Count -gt 1) {
                        "Model defaults ($($recipes.Count) portrait stages)"
                    }
                    else {
                        "$($profile.animation), frame $($profile.frame)"
                    }
                    $selectedPose = [pscustomobject]@{
                        Value = [string] $profile.pose
                        Frame = [int] $profile.frame
                        Label = $recipeLabel
                    }
                    $selectedCameraAngle = ([double] $profile.camera_x).ToString([Globalization.CultureInfo]::InvariantCulture)
                    $selectedCameraRollDegrees = ([double] $profile.camera_roll_degrees).ToString([Globalization.CultureInfo]::InvariantCulture)
                    $selectedLensShiftY = ([double] $profile.lens_shift_y).ToString([Globalization.CultureInfo]::InvariantCulture)
                    $selectedOrthographicScale = ([double] $profile.orthographic_scale).ToString([Globalization.CultureInfo]::InvariantCulture)
                    $frontLightProperty = $profile.PSObject.Properties["front_light_power"]
                    $selectedFrontLightPower = if ($null -eq $frontLightProperty) { 10.0 }
                    else { [double] $frontLightProperty.Value }
                    $selectedOutputMode = [string] $profile.output_mode
                    $selectedGoodPortraits = $false
                    $selectedSize = [int] $profile.size
                    $selectedAnimationModel = [string] $profile.animation_model
                    if ($value.Game -eq "k1" -and
                        (Test-Path -LiteralPath (Join-Path $gameFilesDirectory "S_Female03.mdl") -PathType Leaf) -and
                        (Test-Path -LiteralPath (Join-Path $gameFilesDirectory "S_Female03.mdx") -PathType Leaf)) {
                        $selectedAnimationModel = "S_Female03"
                    }
                    if ([string] $profile.workflow -eq "player_head") {
                        $selectedBodyModel = Get-DefaultBodyModel ([IO.Path]::GetFileNameWithoutExtension($value.Name)) $profile
                    }
                    else {
                        $selectedBodyModel = $null
                    }
                    $selectedBodyTexture = $null
                    $selectedBodyBrightness = 0.5
                    $selectedBackgroundGradients = @{}
                    $poseOverride = $false
                    $cameraOverride = $false
                    $cameraRollOverride = $false
                    $lensShiftOverride = $false
                    $orthographicScaleOverride = $false
                    $frontLightOverride = $false
                    $defaultName = [string] $profile.portrait_name
                    if ($defaultName -eq "model_basename") {
                        $defaultName = Get-DefaultPortraitName $value.Name $value.Game
                    }
                    if ($defaultName.Length -gt 11) {
                        $defaultName = $defaultName.Substring(0, 11)
                    }
                    $selectedPortraitName = $defaultName
                    $message = "Model selected. Ready to generate with the defaults."
                }
            }
        }
        "2" {
            if (-not $canGenerate) {
                $message = "Generate is locked until a model is selected."
            }
            elseif (-not (Test-Path -LiteralPath $generateScript -PathType Leaf)) {
                $message = "Generate-Portrait.ps1 has not been added yet."
            }
            else {
                try {
                    $applicationRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
                    $portraitsRoot = Join-Path $applicationRoot "portraits"
                    $force = $false
                    if (Test-PortraitOutputExists $portraitsRoot $selectedPortraitName $selectedOutputMode $selectedGoodPortraits) {
                        $answer = Read-Host "Portrait output already exists. Replace matching files? (y/N)"
                        if ($answer -notmatch "^(?i:y|yes)$") {
                            $message = "Generation cancelled; existing portraits were preserved."
                            continue
                        }
                        $force = $true
                    }
                    $arguments = @{
                        Model = $selectedModel.FullName
                        OutputMode = $selectedOutputMode
                        PortraitName = $selectedPortraitName
                        Size = $selectedSize
                        AnimationModel = $selectedAnimationModel
                        Force = $force
                    }
                    if ($selectedGoodPortraits) {
                        $arguments.EnableGoodPortraits = $true
                    }
                    if (-not [string]::IsNullOrWhiteSpace($selectedBodyModel)) {
                        $arguments.BodyModel = $selectedBodyModel
                    }
                    if (-not [string]::IsNullOrWhiteSpace($selectedBodyTexture)) {
                        $arguments.BodyTexture = $selectedBodyTexture
                    }
                    if ($selectedModel.Workflow -eq "player_head") {
                        $arguments.BodyBrightness = $selectedBodyBrightness
                    }
                    if ($poseOverride) {
                        $arguments.Pose = $selectedPose.Value
                        $arguments.Frame = $selectedPose.Frame
                    }
                    if ($cameraOverride) {
                        $arguments.CameraAngle = $selectedCameraAngle
                    }
                    if ($cameraRollOverride) {
                        $arguments.CameraRollDegrees = $selectedCameraRollDegrees
                    }
                    if ($lensShiftOverride) {
                        $arguments.LensShiftY = $selectedLensShiftY
                    }
                    if ($orthographicScaleOverride) {
                        $arguments.OrthographicScale = $selectedOrthographicScale
                    }
                    if ($frontLightOverride) {
                        $arguments.FrontLightPower = $selectedFrontLightPower
                    }
                    if (-not [string]::IsNullOrWhiteSpace($selectedWorldColor)) {
                        $arguments.WorldColor = $selectedWorldColor
                    }
                    if ($selectedBackgroundGradients.Count -gt 0) {
                        $arguments.BackgroundGradients = $selectedBackgroundGradients
                    }
                    & $generateScript @arguments
                    $message = "Generation finished."
                }
                catch {
                    $message = "Generation failed: $($_.Exception.Message)"
                }
            }
        }
        "3" {
            Show-ManualSettings
        }
        "4" {
            Show-MaintenanceMenu
        }
        "0" {
            return
        }
        default {
            $message = "Enter a number from 0 to 4."
        }
    }
}
