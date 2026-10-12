function Read-KnownModelRegistry {
    param([Parameter(Mandatory)] [string] $Path)

    $registry = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    if ([int] $registry.schema_version -ne 7) {
        throw "Unsupported known-model schema version: $($registry.schema_version)"
    }

    foreach ($profile in @($registry.models) + @($registry.fallback_profiles)) {
        $defaults = $profile.PSObject.Properties["portrait_defaults"]
        if ($null -eq $defaults) {
            throw "Known-model profile is missing portrait_defaults: $($profile.display_name)"
        }

        $expandedRecipes = foreach ($recipe in @($profile.portraits)) {
            $expanded = [ordered]@{}
            foreach ($property in $defaults.Value.PSObject.Properties) {
                $expanded[$property.Name] = $property.Value
            }
            foreach ($property in $recipe.PSObject.Properties) {
                $expanded[$property.Name] = $property.Value
            }
            [pscustomobject] $expanded
        }
        $profile.portraits = @($expandedRecipes)
    }

    return $registry
}
