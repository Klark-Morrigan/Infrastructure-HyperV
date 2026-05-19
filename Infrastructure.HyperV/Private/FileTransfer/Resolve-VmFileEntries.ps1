<#
.SYNOPSIS
    Resolves a host-side wildcard into the entry shape Copy-VmFiles consumes.

.DESCRIPTION
    Pure host-side helper. Expands the wildcard with Get-ChildItem, drops
    directories, computes the VM target path for each match (flatten or
    mirror-tree), and runs the pre-flight validation pass described in
    docs\dev\implementation\01 - bulk-vm-file-transfer\problem.md.

    No SSH client or file server is touched here. All shape checks happen
    before any returned entry could reach a transport step, which keeps
    the failure mode deterministic and reproducible without a live VM.

.PARAMETER Pattern
    A host-side wildcard accepted by Get-ChildItem -Path (e.g.
    'C:\src\*.json' or 'C:\src\*' with -Recurse).

.PARAMETER TargetDir
    Absolute Linux directory on the VM under which every match lands.
    A trailing separator is tolerated and stripped.

.PARAMETER Recurse
    Descend into subdirectories.

.PARAMETER PreserveRelativePath
    When set, each match keeps its host path relative to the longest
    wildcard-free prefix of Pattern, mirrored under TargetDir. Otherwise
    every match is flattened to TargetDir / basename.

.PARAMETER Owner
    chown argument applied uniformly to every entry. Defaults to
    'root:root' to match Copy-VmFiles' default.

.PARAMETER Mode
    chmod argument applied uniformly to every entry. Defaults to '0644'
    to match Copy-VmFiles' default.

.OUTPUTS
    [PSCustomObject[]] with fields Source, Target, Owner, Mode - the
    exact shape Copy-VmFiles' -Entries parameter accepts.
#>
function Resolve-VmFileEntries {
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Pattern,

        [Parameter(Mandatory)]
        [string] $TargetDir,

        [switch] $Recurse,

        [switch] $PreserveRelativePath,

        [string] $Owner = 'root:root',

        [string] $Mode  = '0644'
    )

    # Derive the source root: the longest leading run of path components in
    # Pattern that contain no wildcard characters. This is the anchor for
    # -PreserveRelativePath, picked at a component boundary so we never
    # relativise mid-component (e.g. 'C:\src\foo*\x' anchors at 'C:\src',
    # not 'C:\src\foo'). Splitting on both separators lets callers pass
    # either flavour on Windows.
    $patternSegments = $Pattern -split '[\\/]'
    $rootSegments = @()
    foreach ($segment in $patternSegments) {
        if ($segment -match '[\*\?\[]') { break }
        $rootSegments += $segment
    }
    $sourceRoot = $rootSegments -join [IO.Path]::DirectorySeparatorChar

    # -File filters directories out at the source so a pattern that matches
    # only directories surfaces as the zero-files error below, matching the
    # contract in problem.md.
    $matched = @(Get-ChildItem -Path $Pattern -Recurse:$Recurse -File `
                                -ErrorAction SilentlyContinue)

    if ($matched.Count -eq 0) {
        throw "Resolve-VmFileEntries: no files matched pattern '$Pattern'."
    }

    $normalizedTargetDir = $TargetDir.TrimEnd('/', '\')

    $entries = @(foreach ($file in $matched) {
        if ($PreserveRelativePath) {
            # Strip the wildcard-free root so the remaining path captures
            # only the host subtree being mirrored. OrdinalIgnoreCase covers
            # Windows' case-insensitive filesystem without false positives.
            $relative = $file.FullName
            if ($sourceRoot -and
                $relative.StartsWith($sourceRoot,
                                     [StringComparison]::OrdinalIgnoreCase)) {
                $relative = $relative.Substring($sourceRoot.Length)
            }
            $relative = $relative.TrimStart('\', '/').Replace('\', '/')
            $target   = "$normalizedTargetDir/$relative"
        }
        else {
            $target = "$normalizedTargetDir/$($file.Name)"
        }

        [PSCustomObject]@{
            Source = $file.FullName
            Target = $target
            Owner  = $Owner
            Mode   = $Mode
        }
    })

    # One uniform duplicate check covers both modes: flatten-mode basename
    # collisions across subtrees and preserve-mode collapses both surface
    # as duplicate Target values.
    $duplicates = $entries | Group-Object Target | Where-Object { $_.Count -gt 1 }
    if ($duplicates) {
        $names = ($duplicates | ForEach-Object { $_.Name }) -join "', '"
        throw "Resolve-VmFileEntries: duplicate VM target path(s): '$names'."
    }

    return ,$entries
}
