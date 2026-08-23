[CmdletBinding()]
param(
    [string]$MaterialRoot = (Get-Location).Path,
    [string]$AdobeSearchRoot = '',
    [string]$OutputRoot = $PSScriptRoot,
    [string]$AfterFXPath = '',
    [int]$TimeoutSeconds = 300,
    [int]$MaxTemplates = 200,
    [int]$MaxLayersPerComp = 200,
    [switch]$IncludeLayerDetails,
    [switch]$AllowExistingAE,
    [switch]$AllowOutputOutsideProject,
    [switch]$LeaveAERunningOnTimeout
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-DirectoryIfMissing {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch) {
            [void]$builder.Append('_')
        }
        else {
            [void]$builder.Append($ch)
        }
    }
    $safe = $builder.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'template.aep'
    }
    return $safe
}

function ConvertTo-JsxStringLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
    return '"' + $escaped + '"'
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Data,
        [int]$Depth = 80
    )
    $json = $Data | ConvertTo-Json -Depth $Depth
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Test-PathIsInside {
    # True when $Path is $Root itself or anywhere beneath it. Both are resolved
    # strings; comparison is case-insensitive because this runs on Windows.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $rootTrimmed = $Root.TrimEnd('\')
    $pathTrimmed = $Path.TrimEnd('\')
    if ([string]::Equals($pathTrimmed, $rootTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $pathTrimmed.StartsWith($rootTrimmed + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ShortHash {
    # First 12 hex characters of SHA-256. Enough to match two records that refer to
    # the same file; not meant to be reversible and not used for anything secret.
    param([Parameter(Mandatory = $true)][string]$Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
    }
    finally {
        $sha.Dispose()
    }
}

function ConvertTo-RedactedTemplateRecord {
    # The public inventory never carries the absolute path of a scanned template.
    # It gets the path relative to the material root (which the operator supplied
    # and already knows), the file name, and a short hash of the absolute path so
    # that records from different runs can still be matched.
    param(
        [Parameter(Mandatory = $true)]$File,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $rootPrefix = $Root.TrimEnd('\') + '\'
    $relative = if ($File.FullName.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $File.FullName.Substring($rootPrefix.Length)
    }
    else {
        $File.Name
    }
    return [ordered]@{
        name = $File.Name
        sourceRelativePath = $relative
        sourceFileName = $File.Name
        sourcePathHash = Get-ShortHash -Value $File.FullName
        lengthBytes = $File.Length
        lastWriteTime = $File.LastWriteTime.ToString('o')
        status = 'queued'
    }
}

$redactionPolicy = 'Template paths are recorded relative to materialRoot plus a short SHA-256 of the absolute path; footage paths are reduced to file name plus hash; text layer contents are reduced to length, hash and shape. No absolute media path and no text content appears in this inventory. (redaction policy v1)'

function Resolve-AfterFXPath {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (Test-Path -LiteralPath $RequestedPath) {
            return (Resolve-Path -LiteralPath $RequestedPath).Path
        }
        throw "AfterFXPath was provided but does not exist: $RequestedPath"
    }

    $knownPaths = @(
        'C:\Program Files\Adobe\Adobe After Effects 2026\Support Files\AfterFX.exe',
        'C:\Program Files\Adobe\Adobe After Effects 2025\Support Files\AfterFX.exe',
        'C:\Program Files\Adobe\Adobe After Effects 2024\Support Files\AfterFX.exe'
    )

    foreach ($path in $knownPaths) {
        if (Test-Path -LiteralPath $path) {
            return (Resolve-Path -LiteralPath $path).Path
        }
    }

    # Where After Effects is installed. Defaults to the standard Program Files
    # location; use -AdobeSearchRoot, or set AE_SEARCH_ROOTS (';'-separated),
    # when it lives on another drive.
    $searchRoots = @()
    if ($AdobeSearchRoot) { $searchRoots += $AdobeSearchRoot }
    if ($env:AE_SEARCH_ROOTS) { $searchRoots += ($env:AE_SEARCH_ROOTS -split ';' | Where-Object { $_ }) }
    $searchRoots += 'C:\Program Files\Adobe'
    $searchRoots = @($searchRoots | Select-Object -Unique)
    foreach ($root in $searchRoots) {
        if (Test-Path -LiteralPath $root) {
            $match = Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'AfterFX.exe' -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                Select-Object -First 1
            if ($null -ne $match) {
                return $match.FullName
            }
        }
    }

    return $null
}

function Wait-ForParserStatusFile {
    # Used when an already-running After Effects was reused: the process we started
    # is only a hand-off stub and the parser is told not to quit a session it does
    # not own, so the status file it writes is the only finish signal.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$WaitSeconds
    )
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    return (Test-Path -LiteralPath $Path)
}

function New-InventoryMarkdown {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $templates = @($Inventory.templates)
    [void]$lines.Add('# AE Template Inventory')
    [void]$lines.Add('')
    [void]$lines.Add("- Generated: $($Inventory.generatedAt)")
    [void]$lines.Add("- Status: $($Inventory.status)")
    [void]$lines.Add(('- Material root: `{0}`' -f $Inventory.materialRoot))
    [void]$lines.Add(('- Output root: `{0}`' -f $Inventory.outputRoot))
    [void]$lines.Add("- AE opened: $($Inventory.afterEffectsOpened)")
    [void]$lines.Add("- Templates parsed: $($Inventory.templateCount)")
    [void]$lines.Add("- Redaction: $($Inventory.redaction.policy)")
    [void]$lines.Add('')

    if ($templates.Count -eq 0) {
        [void]$lines.Add('## Result')
        [void]$lines.Add('')
        [void]$lines.Add('No `.aep` templates were found under the current material root.')
        [void]$lines.Add('')
        [void]$lines.Add('## Future Usage')
        [void]$lines.Add('')
        [void]$lines.Add('1. Place or copy `.aep` templates somewhere under the material root listed above.')
        [void]$lines.Add('2. Run:')
        [void]$lines.Add('')
        [void]$lines.Add('```powershell')
        [void]$lines.Add(('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -MaterialRoot "{1}"' -f $Inventory.runnerPath, $Inventory.materialRoot))
        [void]$lines.Add('```')
        [void]$lines.Add('')
        [void]$lines.Add('3. The runner scans recursively, copies each `.aep` into the scan run folder, opens only those working copies through `AfterFX.exe -r`, and closes projects with `DO_NOT_SAVE_CHANGES`.')
        [void]$lines.Add('4. The parser only inventories project structure and editable slots. It does not render, calculate previews, or save over source templates.')
    }
    else {
        [void]$lines.Add('## Parsed Templates')
        [void]$lines.Add('')
        foreach ($template in $templates) {
            $templateName = if ($template.name) { $template.name } else { $template.sourceFileName }
            [void]$lines.Add("### $templateName")
            [void]$lines.Add('')
            [void]$lines.Add(('- Source (relative to material root): `{0}`' -f $template.sourceRelativePath))
            [void]$lines.Add(('- Source path hash: `{0}`' -f $template.sourcePathHash))
            if ($template.PSObject.Properties.Name -contains 'workingCopyName' -and $template.workingCopyName) {
                [void]$lines.Add(('- Working copy opened by AE: `{0}`' -f $template.workingCopyName))
            }
            [void]$lines.Add("- Status: $($template.status)")
            if ($template.PSObject.Properties.Name -contains 'summary' -and $template.summary) {
                [void]$lines.Add("- Comps: $($template.summary.compCount)")
                [void]$lines.Add("- Footage items: $($template.summary.footageCount)")
                [void]$lines.Add("- Text layers: $($template.summary.textLayerCount)")
                [void]$lines.Add("- Likely media slots: $($template.summary.mediaSlotCount)")
                [void]$lines.Add("- Nested comp links: $($template.summary.nestedCompLinkCount)")
            }
            if ($template.PSObject.Properties.Name -contains 'possibleRenderComps' -and $template.possibleRenderComps -and @($template.possibleRenderComps).Count -gt 0) {
                [void]$lines.Add('- Possible render/main comps:')
                foreach ($comp in @($template.possibleRenderComps | Select-Object -First 5)) {
                    [void]$lines.Add(('  - `{0}` ({1}x{2}, {3} fps, {4} sec, score {5})' -f $comp.name, $comp.width, $comp.height, $comp.frameRate, $comp.durationSeconds, $comp.score))
                }
            }
            if ($template.PSObject.Properties.Name -contains 'detailFile' -and $template.detailFile) {
                [void]$lines.Add(('- Full detail: `{0}`' -f $template.detailFile))
            }
            if ($template.PSObject.Properties.Name -contains 'error' -and $template.error) {
                [void]$lines.Add("- Error: $($template.error)")
            }
            [void]$lines.Add('')
        }
    }

    [void]$lines.Add('## Logs')
    [void]$lines.Add('')
    [void]$lines.Add(('- Run folder: `{0}`' -f $Inventory.logs.runDir))
    [void]$lines.Add(('- Scan log: `{0}`' -f $Inventory.logs.scanLog))
    [void]$lines.Add(('- Status JSON: `{0}`' -f $Inventory.logs.statusJson))
    if ($Inventory.logs.aeStdout) {
        [void]$lines.Add(('- AE stdout: `{0}`' -f $Inventory.logs.aeStdout))
    }
    if ($Inventory.logs.aeStderr) {
        [void]$lines.Add(('- AE stderr: `{0}`' -f $Inventory.logs.aeStderr))
    }

    if ($Inventory.limitations -and @($Inventory.limitations).Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('## Limitations')
        [void]$lines.Add('')
        foreach ($limitation in @($Inventory.limitations)) {
            [void]$lines.Add("- $limitation")
        }
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Write-RunStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Message,
        [hashtable]$Extra = @{}
    )

    $status = [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        stage = $Stage
        message = $Message
    }
    foreach ($key in $Extra.Keys) {
        $status[$key] = $Extra[$key]
    }
    Write-JsonFile -Path $Path -Data $status -Depth 30
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $OutputRoot = $PSScriptRoot
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $OutputRoot = Split-Path -Parent $PSCommandPath
    }
    else {
        $OutputRoot = (Get-Location).Path
    }
}

New-DirectoryIfMissing -Path $OutputRoot
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

# The project root is wherever this script lives ($PSScriptRoot). By default the
# output root must be that folder or something beneath it, so a typo in -OutputRoot
# cannot scatter logs and working copies somewhere unexpected. Pass
# -AllowOutputOutsideProject to write elsewhere on purpose.
$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
$projectRootResolved = (Resolve-Path -LiteralPath $scriptRoot).Path
$outputRootInsideProject = [string]::Equals($OutputRoot.TrimEnd('\'), $projectRootResolved.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase) -or
    $OutputRoot.StartsWith($projectRootResolved.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)
if (-not $AllowOutputOutsideProject -and -not $outputRootInsideProject) {
    throw "OutputRoot must be this script's folder or a subfolder of it unless -AllowOutputOutsideProject is given: $OutputRoot"
}
$runnerPath = $PSCommandPath
# The parser lives beside this script, not in the output root.
$parserPath = Join-Path $scriptRoot 'parse_ae_project.jsx'
$inventoryJsonPath = Join-Path $OutputRoot 'template_inventory.json'
$inventoryMdPath = Join-Path $OutputRoot 'template_inventory.md'
$logsRoot = Join-Path $OutputRoot 'logs'
New-DirectoryIfMissing -Path $logsRoot
# Timestamp for humans, process id and a slice of a GUID so two runs that start in
# the same second (or on two machines sharing the output root) cannot collide.
$runId = '{0}_{1}_{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID, ([guid]::NewGuid().ToString('N').Substring(0, 6))
$runDir = Join-Path $logsRoot "scan_$runId"
New-DirectoryIfMissing -Path $runDir
$scanLogPath = Join-Path $runDir 'scan.log'
$statusJsonPath = Join-Path $runDir 'status.json'
$aeStdoutPath = Join-Path $runDir 'AfterFX.stdout.log'
$aeStderrPath = Join-Path $runDir 'AfterFX.stderr.log'
$aeOutputJsonPath = Join-Path $runDir 'ae_parse_output.json'
$aeStatusJsonPath = Join-Path $runDir 'ae_status.json'
$aeConfigJsonPath = Join-Path $runDir 'ae_parse_config.json'
$aeTemplatesDir = Join-Path $runDir 'templates'
$jsxWrapperPath = Join-Path $runDir 'run_parse_ae_project.jsx'
$workingCopiesDir = Join-Path $runDir 'working_copies'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('o'), $Level, $Message
    Add-Content -LiteralPath $scanLogPath -Value $line -Encoding UTF8
    Write-Host $line
}

try {
    Write-RunStatus -Path $statusJsonPath -Stage 'started' -Message 'AE template inventory scan started.'
    Write-Log "Material root: $MaterialRoot"
    Write-Log "Output root: $OutputRoot"

    # Bound the numeric arguments before anything is launched. The timeout is
    # multiplied into milliseconds later; an unbounded value overflows that, and a
    # zero or negative one would kill After Effects before it has started.
    $timeoutText = "$TimeoutSeconds"
    if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 86400) {
        throw "TimeoutSeconds must be between 1 and 86400 seconds (got $timeoutText)."
    }
    if ($MaxTemplates -lt 1) {
        throw "MaxTemplates must be at least 1 (got $MaxTemplates)."
    }
    if ($MaxLayersPerComp -lt 1) {
        throw "MaxLayersPerComp must be at least 1 (got $MaxLayersPerComp)."
    }

    if ([string]::IsNullOrWhiteSpace($MaterialRoot) -or -not (Test-Path -LiteralPath $MaterialRoot)) {
        $fallbackMaterialRoot = (Get-Location).Path
        if (Test-Path -LiteralPath $fallbackMaterialRoot) {
            Write-Log "Material root was empty or unavailable; falling back to current directory: $fallbackMaterialRoot" 'WARN'
            $MaterialRoot = $fallbackMaterialRoot
        }
    }

    if (-not (Test-Path -LiteralPath $MaterialRoot)) {
        throw "Material root does not exist: $MaterialRoot"
    }
    if (-not (Test-Path -LiteralPath $parserPath)) {
        throw "Parser JSX is missing: $parserPath"
    }

    $materialRootResolved = (Resolve-Path -LiteralPath $MaterialRoot).Path

    # If the output root sat inside the material root, every run would find the
    # working copies and logs of the previous one and scan those as templates.
    if (Test-PathIsInside -Path $OutputRoot -Root $materialRootResolved) {
        throw "OutputRoot must not be inside MaterialRoot (OutputRoot=$OutputRoot, MaterialRoot=$materialRootResolved); the scan would pick up its own working copies and logs."
    }

    # No Sort-Object on the recursive scan: sorting needs the whole tree enumerated
    # first, and -MaxTemplates is there precisely so a huge tree is not. The bounded
    # set is sorted afterwards, which costs nothing. Anything under our own logs
    # folder is excluded defensively even though the check above should make that
    # impossible.
    $logsRootPrefix = $logsRoot.TrimEnd('\') + '\'
    $aepFiles = @(Get-ChildItem -LiteralPath $materialRootResolved -Recurse -File -Filter '*.aep' -ErrorAction SilentlyContinue |
        Where-Object { -not $_.FullName.StartsWith($logsRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First ($MaxTemplates + 1))
    $scanTruncated = $false
    if ($aepFiles.Count -gt $MaxTemplates) {
        $scanTruncated = $true
        $aepFiles = @($aepFiles | Select-Object -First $MaxTemplates)
        Write-Log "More than $MaxTemplates .aep files exist; only the first $MaxTemplates (in enumeration order) are processed. Raise -MaxTemplates to include the rest." 'WARN'
    }
    $aepFiles = @($aepFiles | Sort-Object FullName)
    Write-Log "Found $($aepFiles.Count) .aep file(s)."

    $afterFX = $null
    try {
        $afterFX = Resolve-AfterFXPath -RequestedPath $AfterFXPath
        if ($afterFX) {
            Write-Log "AfterFX path: $afterFX"
        }
        else {
            Write-Log 'AfterFX.exe was not found on known paths.' 'WARN'
        }
    }
    catch {
        Write-Log $_.Exception.Message 'WARN'
    }

    $truncationNote = if ($scanTruncated) { "Only the first $MaxTemplates .aep files were processed; raise -MaxTemplates to include the rest." } else { $null }

    if ($aepFiles.Count -eq 0) {
        $inventory = [ordered]@{
            schemaVersion = 1
            generatedAt = (Get-Date).ToString('o')
            materialRoot = $materialRootResolved
            outputRoot = $OutputRoot
            runnerPath = $runnerPath
            parserPath = $parserPath
            status = 'no_templates_found'
            afterEffectsOpened = $false
            afterEffectsExe = $afterFX
            templateCount = 0
            templates = @()
            redaction = [ordered]@{ policy = $redactionPolicy }
            logs = [ordered]@{
                runDir = $runDir
                scanLog = $scanLogPath
                statusJson = $statusJsonPath
                aeStdout = $null
                aeStderr = $null
            }
            limitations = @(
                'No .aep files were present under the current material root, so no AE project structure could be parsed.',
                'The JSX parser is ready for future .aep files but was not invoked in this run.'
            )
        }
        Write-JsonFile -Path $inventoryJsonPath -Data $inventory
        New-InventoryMarkdown -Inventory $inventory -Path $inventoryMdPath
        Write-RunStatus -Path $statusJsonPath -Stage 'no_templates_found' -Message 'No .aep templates were found under the material root.' -Extra @{
            templateCount = 0
            afterEffectsOpened = $false
            inventoryJson = $inventoryJsonPath
            inventoryMarkdown = $inventoryMdPath
        }
        Write-Log "Wrote inventory: $inventoryJsonPath"
        Write-Log "Wrote markdown: $inventoryMdPath"
        exit 0
    }

    if (-not $afterFX) {
        $templates = @(
            foreach ($file in $aepFiles) {
                $record = ConvertTo-RedactedTemplateRecord -File $file -Root $materialRootResolved
                $record.status = 'not_parsed_afterfx_not_found'
                $record
            }
        )
        $limitations = @(
            'Templates were found, but AfterFX.exe was not available on known paths and no parser run was attempted.',
            'Install After Effects or pass -AfterFXPath to scan_ae_templates.ps1.'
        )
        if ($truncationNote) { $limitations += $truncationNote }
        $inventory = [ordered]@{
            schemaVersion = 1
            generatedAt = (Get-Date).ToString('o')
            materialRoot = $materialRootResolved
            outputRoot = $OutputRoot
            runnerPath = $runnerPath
            parserPath = $parserPath
            status = 'templates_found_afterfx_not_found'
            afterEffectsOpened = $false
            afterEffectsExe = $null
            templateCount = $templates.Count
            templates = $templates
            redaction = [ordered]@{ policy = $redactionPolicy }
            logs = [ordered]@{
                runDir = $runDir
                scanLog = $scanLogPath
                statusJson = $statusJsonPath
                aeStdout = $null
                aeStderr = $null
            }
            limitations = $limitations
        }
        Write-JsonFile -Path $inventoryJsonPath -Data $inventory
        New-InventoryMarkdown -Inventory $inventory -Path $inventoryMdPath
        Write-RunStatus -Path $statusJsonPath -Stage 'afterfx_not_found' -Message 'Templates were found but AfterFX.exe could not be resolved.' -Extra @{
            templateCount = $templates.Count
            afterEffectsOpened = $false
            inventoryJson = $inventoryJsonPath
            inventoryMarkdown = $inventoryMdPath
        }
        exit 2
    }

    $existingAe = @(Get-Process -Name AfterFX,AfterFX.com -ErrorAction SilentlyContinue)
    if ($existingAe.Count -gt 0 -and -not $AllowExistingAE) {
        $templates = @(
            foreach ($file in $aepFiles) {
                $record = ConvertTo-RedactedTemplateRecord -File $file -Root $materialRootResolved
                $record.status = 'not_parsed_existing_ae_process'
                $record
            }
        )
        $limitations = @(
            'An After Effects process was already running, so the parser did not open AE to avoid disturbing an existing project.',
            'Close AE and rerun the script, or use -AllowExistingAE only when the running AE session is known to be disposable.'
        )
        if ($truncationNote) { $limitations += $truncationNote }
        $inventory = [ordered]@{
            schemaVersion = 1
            generatedAt = (Get-Date).ToString('o')
            materialRoot = $materialRootResolved
            outputRoot = $OutputRoot
            runnerPath = $runnerPath
            parserPath = $parserPath
            status = 'templates_found_existing_ae_process'
            afterEffectsOpened = $false
            afterEffectsExe = $afterFX
            templateCount = $templates.Count
            templates = $templates
            redaction = [ordered]@{ policy = $redactionPolicy }
            logs = [ordered]@{
                runDir = $runDir
                scanLog = $scanLogPath
                statusJson = $statusJsonPath
                aeStdout = $null
                aeStderr = $null
            }
            limitations = $limitations
        }
        Write-JsonFile -Path $inventoryJsonPath -Data $inventory
        New-InventoryMarkdown -Inventory $inventory -Path $inventoryMdPath
        Write-RunStatus -Path $statusJsonPath -Stage 'existing_ae_process' -Message 'Existing AE process detected; parser not run.' -Extra @{
            templateCount = $templates.Count
            afterEffectsOpened = $false
            inventoryJson = $inventoryJsonPath
            inventoryMarkdown = $inventoryMdPath
            existingProcessIds = @($existingAe | ForEach-Object { $_.Id })
        }
        exit 3
    }
    # From here on, an AE that was already running is one the operator explicitly
    # allowed us to reuse. The parser must then leave it open when it is done.
    $reusingExistingAe = ($existingAe.Count -gt 0)

    New-DirectoryIfMissing -Path $workingCopiesDir
    New-DirectoryIfMissing -Path $aeTemplatesDir
    $templateConfigs = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($file in $aepFiles) {
        $index++
        $safeName = ConvertTo-SafeFileName -Name $file.Name
        $copyName = '{0:D3}_{1}' -f $index, $safeName
        $copyPath = Join-Path $workingCopiesDir $copyName
        Copy-Item -LiteralPath $file.FullName -Destination $copyPath -Force
        Write-Log "Copied template working file: $($file.FullName) -> $copyPath"
        $record = ConvertTo-RedactedTemplateRecord -File $file -Root $materialRootResolved
        [void]$templateConfigs.Add([ordered]@{
            index = $index
            name = $file.Name
            sourceRelativePath = $record.sourceRelativePath
            sourceFileName = $record.sourceFileName
            sourcePathHash = $record.sourcePathHash
            # The parser needs the absolute path of the working copy to open it. It is
            # inside our own run folder and never reaches the public inventory.
            workingCopyPath = $copyPath
            lengthBytes = $file.Length
            lastWriteTime = $file.LastWriteTime.ToString('o')
        })
    }

    $config = [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        materialRoot = $materialRootResolved
        outputRoot = $OutputRoot
        runDir = $runDir
        outputJsonPath = $aeOutputJsonPath
        statusJsonPath = $aeStatusJsonPath
        templatesDir = $aeTemplatesDir
        allowExistingAE = $reusingExistingAe
        includeLayerDetails = [bool]$IncludeLayerDetails
        maxLayersPerComp = $MaxLayersPerComp
        templates = @($templateConfigs)
    }
    Write-JsonFile -Path $aeConfigJsonPath -Data $config -Depth 40

    $wrapperLines = @(
        '#target aftereffects',
        '$.global.AE_TEMPLATE_PARSE_CONFIG = ' + (ConvertTo-JsxStringLiteral -Value $aeConfigJsonPath) + ';',
        '$.evalFile(File(' + (ConvertTo-JsxStringLiteral -Value $parserPath) + '));'
    )
    Set-Content -LiteralPath $jsxWrapperPath -Value $wrapperLines -Encoding UTF8

    Write-RunStatus -Path $statusJsonPath -Stage 'launching_afterfx' -Message 'Launching AfterFX.exe with JSX parser.' -Extra @{
        templateCount = $templateConfigs.Count
        afterEffectsExe = $afterFX
        jsxWrapper = $jsxWrapperPath
        reusingExistingAe = $reusingExistingAe
    }
    Write-Log "Launching AE parser through AfterFX.exe -r $jsxWrapperPath"

    $argumentString = '-r "{0}"' -f ($jsxWrapperPath.Replace('"', '\"'))
    $process = Start-Process -FilePath $afterFX -ArgumentList $argumentString -RedirectStandardOutput $aeStdoutPath -RedirectStandardError $aeStderrPath -WindowStyle Hidden -PassThru
    if (-not $reusingExistingAe) {
        # We launched this AE; the parser quits it when done, so the process exiting
        # is the finish signal.
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    }
    else {
        $completed = Wait-ForParserStatusFile -Path $aeStatusJsonPath -WaitSeconds $TimeoutSeconds
    }
    if (-not $completed) {
        Write-Log "AfterFX parser timed out after $timeoutText seconds. Modal prompt or blocked startup is possible." 'ERROR'
        if (-not $LeaveAERunningOnTimeout -and -not $reusingExistingAe) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Write-Log "Stopped timed-out AfterFX process id $($process.Id)."
            }
            catch {
                Write-Log "Could not stop timed-out AfterFX process id $($process.Id): $($_.Exception.Message)" 'WARN'
            }
        }

        $templates = @(
            foreach ($item in $templateConfigs) {
                [ordered]@{
                    name = $item.name
                    sourceRelativePath = $item.sourceRelativePath
                    sourceFileName = $item.sourceFileName
                    sourcePathHash = $item.sourcePathHash
                    workingCopyPath = $item.workingCopyPath
                    workingCopyName = [System.IO.Path]::GetFileName($item.workingCopyPath)
                    lengthBytes = $item.lengthBytes
                    lastWriteTime = $item.lastWriteTime
                    status = 'not_parsed_afterfx_timeout'
                }
            }
        )
        $limitations = @(
            'AfterFX.exe did not finish before the timeout. A modal prompt, licensing dialog, or project-open error may need manual attention.',
            'Only working copies were opened or targeted. Source .aep files were not saved or rendered.'
        )
        if ($truncationNote) { $limitations += $truncationNote }
        $inventory = [ordered]@{
            schemaVersion = 1
            generatedAt = (Get-Date).ToString('o')
            materialRoot = $materialRootResolved
            outputRoot = $OutputRoot
            runnerPath = $runnerPath
            parserPath = $parserPath
            status = 'afterfx_timeout'
            afterEffectsOpened = $true
            afterEffectsExe = $afterFX
            templateCount = $templates.Count
            templates = $templates
            redaction = [ordered]@{ policy = $redactionPolicy }
            logs = [ordered]@{
                runDir = $runDir
                scanLog = $scanLogPath
                statusJson = $statusJsonPath
                aeStdout = $aeStdoutPath
                aeStderr = $aeStderrPath
            }
            limitations = $limitations
        }
        Write-JsonFile -Path $inventoryJsonPath -Data $inventory
        New-InventoryMarkdown -Inventory $inventory -Path $inventoryMdPath
        Write-RunStatus -Path $statusJsonPath -Stage 'afterfx_timeout' -Message 'AfterFX parser timed out.' -Extra @{
            templateCount = $templates.Count
            afterEffectsOpened = $true
            inventoryJson = $inventoryJsonPath
            inventoryMarkdown = $inventoryMdPath
            processId = $process.Id
        }
        exit 4
    }

    $exitCodeText = if ($process.HasExited) { "$($process.ExitCode)" } else { 'n/a (reused session left running)' }
    Write-Log "AfterFX exited with code $exitCodeText."

    # The parser writes its own status file last. Only a status of 'ok' means the
    # output file is complete; anything else (or no file at all) is a parser failure
    # even when AfterFX itself exited cleanly.
    if (-not (Test-Path -LiteralPath $aeStatusJsonPath)) {
        throw "AfterFX finished but the parser wrote no status file: $aeStatusJsonPath"
    }
    $aeStatus = Get-Content -LiteralPath $aeStatusJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($aeStatus.stage -eq 'ok') {
        Write-Log "Parser status: ok ($($aeStatus.message))"
    }
    else {
        throw "Parser reported stage '$($aeStatus.stage)': $($aeStatus.message)"
    }
    if (-not (Test-Path -LiteralPath $aeOutputJsonPath)) {
        throw "AfterFX finished but parser output was not created: $aeOutputJsonPath"
    }

    $aeData = Get-Content -LiteralPath $aeOutputJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $templates = @($aeData.templates)
    $parsedCount = @($templates | Where-Object { $_.status -eq 'parsed' }).Count
    $inventoryStatus = if ($parsedCount -eq $templates.Count) { 'parsed' } elseif ($parsedCount -gt 0) { 'partially_parsed' } else { 'parse_failed' }
    $limitations = @(
        'This inventory uses static project inspection only. It does not render, preview, execute compositions, or validate visual output.',
        'Likely media slots and main comps are heuristic suggestions based on names, layer sources, duration, and nesting.',
        'Per-template detail (comps, footage, text layers, media slots) is in the templates folder of the run directory, one JSON file per template; this inventory holds the summaries.'
    )
    if ($truncationNote) { $limitations += $truncationNote }
    $inventory = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('o')
        materialRoot = $materialRootResolved
        outputRoot = $OutputRoot
        runnerPath = $runnerPath
        parserPath = $parserPath
        status = $inventoryStatus
        afterEffectsOpened = $true
        afterEffectsExe = $afterFX
        templateCount = $templates.Count
        parsedTemplateCount = $parsedCount
        templates = $templates
        redaction = [ordered]@{ policy = $redactionPolicy }
        logs = [ordered]@{
            runDir = $runDir
            scanLog = $scanLogPath
            statusJson = $statusJsonPath
            aeStdout = $aeStdoutPath
            aeStderr = $aeStderrPath
            aeParserOutput = $aeOutputJsonPath
            aeParserStatus = $aeStatusJsonPath
            aeTemplateDetailsDir = $aeTemplatesDir
        }
        limitations = $limitations
    }
    Write-JsonFile -Path $inventoryJsonPath -Data $inventory -Depth 90
    New-InventoryMarkdown -Inventory $inventory -Path $inventoryMdPath
    Write-RunStatus -Path $statusJsonPath -Stage $inventoryStatus -Message 'AE parser run completed.' -Extra @{
        templateCount = $templates.Count
        parsedTemplateCount = $parsedCount
        afterEffectsOpened = $true
        inventoryJson = $inventoryJsonPath
        inventoryMarkdown = $inventoryMdPath
        afterEffectsExitCode = $exitCodeText
    }
    Write-Log "Wrote inventory: $inventoryJsonPath"
    Write-Log "Wrote markdown: $inventoryMdPath"
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Log $message 'ERROR'
    $inventory = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('o')
        materialRoot = $MaterialRoot
        outputRoot = $OutputRoot
        runnerPath = $runnerPath
        parserPath = $parserPath
        status = 'runner_error'
        afterEffectsOpened = $false
        afterEffectsExe = $null
        templateCount = 0
        templates = @()
        redaction = [ordered]@{ policy = $redactionPolicy }
        logs = [ordered]@{
            runDir = $runDir
            scanLog = $scanLogPath
            statusJson = $statusJsonPath
            aeStdout = $aeStdoutPath
            aeStderr = $aeStderrPath
        }
        limitations = @(
            'The runner stopped before completing inventory generation.',
            $message
        )
    }
    Write-JsonFile -Path $inventoryJsonPath -Data $inventory -Depth 40
    New-InventoryMarkdown -Inventory $inventory -Path $inventoryMdPath
    Write-RunStatus -Path $statusJsonPath -Stage 'runner_error' -Message $message -Extra @{
        inventoryJson = $inventoryJsonPath
        inventoryMarkdown = $inventoryMdPath
    }
    exit 1
}
