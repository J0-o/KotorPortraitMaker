function Get-KotorModelGame {
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [byte[]]::new(16)
    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Read($bytes, 0, $bytes.Length) -ne $bytes.Length) {
            throw "MDL header is incomplete: $Path"
        }
    }
    finally {
        $stream.Dispose()
    }

    if ([BitConverter]::ToUInt32($bytes, 0) -ne 0) {
        throw "Only binary KOTOR MDL files are supported: $Path"
    }

    $geometryFunction = [BitConverter]::ToUInt32($bytes, 12)
    switch ($geometryFunction) {
        { $_ -in @(0x00413670, 0x0040ED10) } { return "k1" }
        { $_ -in @(0x00416310, 0x004165B0) } { return "k2" }
        default {
            throw ("Unrecognized KOTOR MDL geometry header 0x{0:X8}: {1}" -f $geometryFunction, $Path)
        }
    }
}

function Get-DefaultPortraitName {
    param(
        [Parameter(Mandatory)] [string] $ModelName,
        [ValidateSet("k1", "k2")] [string] $Game
    )

    $name = ([IO.Path]::GetFileNameWithoutExtension($ModelName) -replace "[^A-Za-z0-9_]", "_").ToLowerInvariant()
    if ($Game -eq "k1" -and $name -match "^((?:pfh|pmh)[abc])0([1-9])$") {
        return $Matches[1] + $Matches[2]
    }
    return $name
}

function Test-KotorModelDependencyName {
    param([Parameter(Mandatory)] [string] $ModelName)

    $name = [IO.Path]::GetFileNameWithoutExtension($ModelName)
    return $name -match "^(?i:S_|N_Comm|PFB|PMB)" -or
        $name -match "(?i)(?:BA|BB(?:H|\d+)?)$"
}
