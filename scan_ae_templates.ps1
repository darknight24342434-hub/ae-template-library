[CmdletBinding()]
param(
    [string]$MaterialRoot = (Get-Location).Path,
    [string]$AdobeSearchRoot = '',
    [string]$OutputRoot = $PSScriptRoot,
    [string]$AfterFXPath = '',
    [int]$TimeoutSeconds = 300,
    [switch]$AllowExistingAE,
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

function Resolve-AfterFXPath {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        if (Test-Path -LiteralPath $RequestedPath) {
            return (Resolve-Path -LiteralPath $RequestedPath).Path
        }
        throw "AfterFXPath was provided but does not exist: $RequestedPath"
    }

    $knownPaths = @(
        'F:\ADOBE\Adobe After Effects 2026\Support Files\AfterFX.exe',
        'F:\ADOBE\Adobe After Effects 2025\Support Files\AfterFX.exe',
        'F:\ADOBE\Adobe After Effects 2024\Support Files\AfterFX.exe',
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
            $templateName = if ($template.name) { $template.name } else { [System.IO.Path]::GetFileName($template.sourcePath) }
            [void]$lines.Add("### $templateName")
            [void]$lines.Add('')
            [void]$lines.Add(('- Source: `{0}`' -f $template.sourcePath))
            if ($template.workingCopyPath) {
                [void]$lines.Add(('- Working copy opened by AE: `{0}`' -f $template.workingCopyPath))
            }
            [void]$lines.Add("- Status: $($template.status)")
            if ($template.summary) {
                [void]$lines.Add("- Comps: $($template.summary.compCount)")
                [void]$lines.Add("- Footage items: $($template.summary.footageCount)")
                [void]$lines.Add("- Text layers: $($template.summary.textLayerCount)")
                [void]$lines.Add("- Likely media slots: $($template.summary.mediaSlotCount)")
                [void]$lines.Add("- Nested comp links: $($template.summary.nestedCompLinkCount)")
            }
            if ($template.possibleRenderComps -and @($template.possibleRenderComps).Count -gt 0) {
                [void]$lines.Add('- Possible render/main comps:')
                foreach ($comp in @($template.possibleRenderComps | Select-Object -First 5)) {
                    [void]$lines.Add(('  - `{0}` ({1}x{2}, {3} fps, {4} sec, score {5})' -f $comp.name, $comp.width, $comp.height, $comp.frameRate, $comp.durationSeconds, $comp.score))
                }
            }
            if ($template.error) {
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
$runnerPath = $PSCommandPath
$parserPath = Join-Path $OutputRoot 'parse_ae_project.jsx'
$inventoryJsonPath = Join-Path $OutputRoot 'template_inventory.json'
$inventoryMdPath = Join-Path $OutputRoot 'template_inventory.md'
$logsRoot = Join-Path $OutputRoot 'logs'
New-DirectoryIfMissing -Path $logsRoot
$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$runDir = Join-Path $logsRoot "scan_$runId"
New-DirectoryIfMissing -Path $runDir
$scanLogPath = Join-Path $runDir 'scan.log'
$statusJsonPath = Join-Path $runDir 'status.json'
$aeStdoutPath = Join-Path $runDir 'AfterFX.stdout.log'
$aeStderrPath = Join-Path $runDir 'AfterFX.stderr.log'
$aeOutputJsonPath = Join-Path $runDir 'ae_parse_output.json'
$aeStatusJsonPath = Join-Path $runDir 'ae_status.json'
$aeConfigJsonPath = Join-Path $runDir 'ae_parse_config.json'
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
    $aepFiles = @(Get-ChildItem -LiteralPath $materialRootResolved -Recurse -File -Filter '*.aep' -ErrorAction SilentlyContinue | Sort-Object FullName)
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
                [ordered]@{
                    name = $file.Name
                    sourcePath = $file.FullName
                    lengthBytes = $file.Length
                    lastWriteTime = $file.LastWriteTime.ToString('o')
                    status = 'not_parsed_afterfx_not_found'
                }
            }
        )
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
            logs = [ordered]@{
                runDir = $runDir
                scanLog = $scanLogPath
                statusJson = $statusJsonPath
                aeStdout = $null
                aeStderr = $null
            }
            limitations = @(
                'Templates were found, but AfterFX.exe was not available on known paths and no parser run was attempted.',
                'Install After Effects or pass -AfterFXPath to scan_ae_templates.ps1.'
            )
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
                [ordered]@{
                    name = $file.Name
                    sourcePath = $file.FullName
                    lengthBytes = $file.Length
                    lastWriteTime = $file.LastWriteTime.ToString('o')
                    status = 'not_parsed_existing_ae_process'
                }
            }
        )
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
            logs = [ordered]@{
                runDir = $runDir
                scanLog = $scanLogPath
                statusJson = $statusJsonPath
                aeStdout = $null
                aeStderr = $null
            }
            limitations = @(
                'An After Effects process was already running, so the parser did not open AE to avoid disturbing an existing project.',
                'Close AE and rerun the script, or use -AllowExistingAE only when the running AE session is known to be disposable.'
            )
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

    New-DirectoryIfMissing -Path $workingCopiesDir
    $templateConfigs = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($file in $aepFiles) {
        $index++
        $safeName = ConvertTo-SafeFileName -Name $file.Name
        $copyName = '{0:D3}_{1}' -f $index, $safeName
        $copyPath = Join-Path $workingCopiesDir $copyName
        Copy-Item -LiteralPath $file.FullName -Destination $copyPath -Force
        Write-Log "Copied template working file: $($file.FullName) -> $copyPath"
        [void]$templateConfigs.Add([ordered]@{
            index = $index
            name = $file.Name
            sourcePath = $file.FullName
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
    }
    Write-Log "Launching AE parser through AfterFX.exe -r $jsxWrapperPath"

    $argumentString = '-r "{0}"' -f ($jsxWrapperPath.Replace('"', '\"'))
    $process = Start-Process -FilePath $afterFX -ArgumentList $argumentString -RedirectStandardOutput $aeStdoutPath -RedirectStandardError $aeStderrPath -WindowStyle Hidden -PassThru
    $completed = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        Write-Log "AfterFX parser timed out after $TimeoutSeconds seconds. Modal prompt or blocked startup is possible." 'ERROR'
        if (-not $LeaveAERunningOnTimeout) {
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
                    sourcePath = $item.sourcePath
                    workingCopyPath = $item.workingCopyPath
                    lengthBytes = $item.lengthBytes
                    lastWriteTime = $item.lastWriteTime
                    status = 'not_parsed_afterfx_timeout'
                }
            }
        )
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
            logs = [ordered]@{
                runDir = $runDir
                scanLog = $scanLogPath
                statusJson = $statusJsonPath
                aeStdout = $aeStdoutPath
                aeStderr = $aeStderrPath
            }
            limitations = @(
                'AfterFX.exe did not finish before the timeout. A modal prompt, licensing dialog, or project-open error may need manual attention.',
                'Only working copies were opened or targeted. Source .aep files were not saved or rendered.'
            )
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

    Write-Log "AfterFX exited with code $($process.ExitCode)."
    if (-not (Test-Path -LiteralPath $aeOutputJsonPath)) {
        throw "AfterFX finished but parser output was not created: $aeOutputJsonPath"
    }

    $aeData = Get-Content -LiteralPath $aeOutputJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $templates = @($aeData.templates)
    $parsedCount = @($templates | Where-Object { $_.status -eq 'parsed' }).Count
    $inventoryStatus = if ($parsedCount -eq $templates.Count) { 'parsed' } elseif ($parsedCount -gt 0) { 'partially_parsed' } else { 'parse_failed' }
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
        logs = [ordered]@{
            runDir = $runDir
            scanLog = $scanLogPath
            statusJson = $statusJsonPath
            aeStdout = $aeStdoutPath
            aeStderr = $aeStderrPath
            aeParserOutput = $aeOutputJsonPath
            aeParserStatus = $aeStatusJsonPath
        }
        limitations = @(
            'This inventory uses static project inspection only. It does not render, preview, execute compositions, or validate visual output.',
            'Likely media slots and main comps are heuristic suggestions based on names, layer sources, duration, and nesting.'
        )
    }
    Write-JsonFile -Path $inventoryJsonPath -Data $inventory -Depth 90
    New-InventoryMarkdown -Inventory $inventory -Path $inventoryMdPath
    Write-RunStatus -Path $statusJsonPath -Stage $inventoryStatus -Message 'AE parser run completed.' -Extra @{
        templateCount = $templates.Count
        parsedTemplateCount = $parsedCount
        afterEffectsOpened = $true
        inventoryJson = $inventoryJsonPath
        inventoryMarkdown = $inventoryMdPath
        afterEffectsExitCode = $process.ExitCode
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
