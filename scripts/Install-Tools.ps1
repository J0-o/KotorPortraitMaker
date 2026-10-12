$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Resolve application paths independently of the caller's location.
$applicationDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$settingsPath = Join-Path $applicationDirectory "settings.json"
$scenePath = Join-Path $applicationDirectory "scenes\portrait_default.blend"
$toolsDirectory = Join-Path $applicationDirectory "tools"
$imageMagickDirectory = Join-Path $toolsDirectory "imagemagick"
$imageMagickExecutable = Join-Path $imageMagickDirectory "magick.exe"
$imageMagickUrl = "https://github.com/ImageMagick/ImageMagick/releases/download/7.1.2-31/ImageMagick-7.1.2-31-portable-Q16-x64.7z"

# Read a previously selected Blender executable from application settings.
function Get-SavedBlenderExecutable {
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        return $null
    }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        return [string] $settings.blender_executable
    }
    catch {
        return $null
    }
}

# Ask the user to locate an existing Blender executable.
function Select-BlenderExecutable {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.OpenFileDialog]::new()
    try {
        $dialog.Title = "Select Blender"
        $dialog.Filter = "Blender executable (blender.exe)|blender.exe"
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        $dialog.RestoreDirectory = $true
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) {
            return $null
        }
        return $dialog.FileName
    }
    finally {
        $dialog.Dispose()
    }
}

# Confirm that Blender opens the bundled scene with KotorBlender enabled.
function Test-BlenderSetup {
    param([Parameter(Mandatory)] [string] $Executable)

    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf) -or
        -not (Test-Path -LiteralPath $scenePath -PathType Leaf)) {
        return $false
    }
    $savedErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Executable `
            --background $scenePath `
            --python-exit-code 1 `
            --python-expr "import bpy; assert bpy.data.filepath; assert hasattr(bpy.ops.kb, 'mdlimport')" `
            2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = $savedErrorPreference
    }
}

# Save the validated Blender path for every application script.
function Save-BlenderExecutable {
    param([Parameter(Mandatory)] [string] $Executable)

    [pscustomobject]@{
        blender_executable = [IO.Path]::GetFullPath($Executable)
    } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

# Copy the extracted ImageMagick directory into the application tools folder.
function Install-ImageMagick {
    $tarCommand = Get-Command "tar.exe" -ErrorAction SilentlyContinue
    if ($null -eq $tarCommand) {
        throw "Windows tar.exe is required to extract ImageMagick."
    }

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("kotor-portrait-tools-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        $archive = Join-Path $temporaryDirectory "imagemagick.7z"
        $extracted = Join-Path $temporaryDirectory "imagemagick"
        New-Item -ItemType Directory -Path $extracted | Out-Null
        Write-Host "Downloading ImageMagick 7.1.2-31..."
        Invoke-WebRequest -Uri $imageMagickUrl -OutFile $archive -UseBasicParsing
        & $tarCommand.Source -xf $archive -C $extracted
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe could not extract the ImageMagick archive."
        }

        $executable = Get-ChildItem -LiteralPath $extracted -Recurse -File -Filter "magick.exe" | Select-Object -First 1
        if ($null -eq $executable) {
            throw "The ImageMagick archive does not contain magick.exe."
        }
        if (Test-Path -LiteralPath $imageMagickDirectory) {
            Remove-Item -LiteralPath $imageMagickDirectory -Recurse -Force
        }
        New-Item -ItemType Directory -Path $imageMagickDirectory -Force | Out-Null
        Get-ChildItem -LiteralPath $executable.Directory.FullName -Force |
            Copy-Item -Destination $imageMagickDirectory -Recurse -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Reuse a valid saved path or ask the user to select Blender again.
$blenderExecutable = Get-SavedBlenderExecutable
if (-not [string]::IsNullOrWhiteSpace($blenderExecutable) -and
    (Test-BlenderSetup $blenderExecutable)) {
    Write-Host "Using Blender: $blenderExecutable"
}
else {
    $blenderExecutable = Select-BlenderExecutable
    if ([string]::IsNullOrWhiteSpace($blenderExecutable)) {
        Write-Host "Blender selection was cancelled." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-BlenderSetup $blenderExecutable)) {
        Write-Host "Blender could not open the portrait scene with KotorBlender enabled." -ForegroundColor Red
        Read-Host "Check Blender and KotorBlender, then press Enter to exit" | Out-Null
        exit 1
    }
    Save-BlenderExecutable $blenderExecutable
    Write-Host "Saved Blender path: $blenderExecutable"
}

# Keep ImageMagick as the only tool installed automatically by the application.
if (-not (Test-Path -LiteralPath $imageMagickExecutable -PathType Leaf)) {
    try {
        Install-ImageMagick
        Write-Host "Installed ImageMagick at $imageMagickExecutable."
    }
    catch {
        Write-Host "ImageMagick installation failed: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host "Press Enter to exit" | Out-Null
        exit 1
    }
}
else {
    Write-Host "ImageMagick already exists at $imageMagickExecutable."
}

Write-Host "Blender, KotorBlender, and ImageMagick are ready."
