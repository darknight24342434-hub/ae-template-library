import json
import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def _function_body(source, name):
    match = re.search(rf"function {re.escape(name)}(?:\s*\([^)]*\))?\s*\{{", source)
    assert match, f"{name} was not found"
    start = match.end()
    depth = 1
    index = start
    while index < len(source) and depth:
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
        index += 1
    assert depth == 0, f"{name} body did not close"
    return source[start : index - 1]


def _region_between(start_text, end_text):
    return RUNNER[RUNNER.index(start_text) : RUNNER.index(end_text)]


def test_requested_afterfx_path_must_exist_before_it_can_be_used():
    body = _function_body(RUNNER, "Resolve-AfterFXPath")

    requested_branch = body[body.index("if (-not [string]::IsNullOrWhiteSpace($RequestedPath))") : body.index("$knownPaths = @(")]
    assert "Test-Path -LiteralPath $RequestedPath" in requested_branch
    assert "Resolve-Path -LiteralPath $RequestedPath" in requested_branch
    assert 'throw "AfterFXPath was provided but does not exist: $RequestedPath"' in requested_branch


def test_no_template_branch_writes_empty_inventory_and_does_not_open_afterfx():
    branch = _region_between("if ($aepFiles.Count -eq 0)", "if (-not $afterFX)")

    assert "status = 'no_templates_found'" in branch
    assert "afterEffectsOpened = $false" in branch
    assert "templates = @()" in branch
    assert "Write-JsonFile -Path $inventoryJsonPath -Data $inventory" in branch
    assert "New-InventoryMarkdown -Inventory $inventory -Path $inventoryMdPath" in branch
    assert "exit 0" in branch


def test_afterfx_missing_branch_records_each_template_without_working_copy():
    branch = _region_between("if (-not $afterFX)", "$existingAe = @(")

    assert "status = 'templates_found_afterfx_not_found'" in branch
    assert "status = 'not_parsed_afterfx_not_found'" in branch
    assert "afterEffectsOpened = $false" in branch
    assert "workingCopyPath" not in branch
    assert "exit 2" in branch


def test_existing_afterfx_branch_requires_explicit_override_before_launch():
    guard_region = _region_between("$existingAe = @(", "New-DirectoryIfMissing -Path $workingCopiesDir")

    assert "$existingAe.Count -gt 0 -and -not $AllowExistingAE" in guard_region
    assert "status = 'templates_found_existing_ae_process'" in guard_region
    assert "status = 'not_parsed_existing_ae_process'" in guard_region
    assert "existingProcessIds" in guard_region
    assert "exit 3" in guard_region


def test_timeout_branch_marks_working_copies_not_parsed_and_can_stop_afterfx():
    branch = _region_between("if (-not $completed)", "Write-Log \"AfterFX exited with code")

    assert "status = 'not_parsed_afterfx_timeout'" in branch
    assert "status = 'afterfx_timeout'" in branch
    assert "afterEffectsOpened = $true" in branch
    assert "workingCopyPath = $item.workingCopyPath" in branch
    assert "Stop-Process -Id $process.Id -Force" in branch
    assert "exit 4" in branch


def test_parser_batch_loop_keeps_successful_templates_when_one_template_fails():
    parse_loop = JSX[JSX.index("for (var i = 0; i < config.templates.length; i++)") :]

    assert "output.templates.push(scanProject(templateConfig));" in parse_loop
    assert "catch (templateError)" in parse_loop
    assert "status: 'error'" in parse_loop
    assert "error: String(templateError)" in parse_loop
    assert "writeText(config.outputJsonPath, toJson(output));" in parse_loop


def test_jsx_numeric_and_json_boundaries_are_serialized_safely():
    round_body = _function_body(JSX, "roundNumber")
    json_body = _function_body(JSX, "toJson")

    assert "typeof value !== 'number' || !isFinite(value)" in round_body
    assert "return null;" in round_body
    assert "return isFinite(value) ? String(value) : 'null';" in json_body
    assert "if (value === null || value === undefined)" in json_body


def test_inventory_json_matches_empty_scan_terminal_contract():
    inventory = json.loads((PROJECT_ROOT / "template_inventory.json").read_text(encoding="utf-8-sig"))

    assert inventory["schemaVersion"] == 1
    assert inventory["status"] == "no_templates_found"
    assert inventory["afterEffectsOpened"] is False
    assert inventory["templateCount"] == 0
    assert inventory["templates"] == []
    assert {"runDir", "scanLog", "statusJson", "aeStdout", "aeStderr"} <= set(inventory["logs"])
