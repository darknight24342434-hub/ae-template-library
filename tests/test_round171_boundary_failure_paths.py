import json
import subprocess
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = PROJECT_ROOT / "scan_ae_templates.ps1"
PARSER_PATH = PROJECT_ROOT / "parse_ae_project.jsx"
TEST_RUNTIME = PROJECT_ROOT / "tests" / "_round171_runtime"
EMPTY_MATERIAL_ROOT = PROJECT_ROOT / "tests" / "fixtures" / "round171_empty_material_root"


def _read_text(path):
    return path.read_text(encoding="utf-8-sig")


def test_empty_material_root_runner_branch_is_executable_without_afterfx():
    EMPTY_MATERIAL_ROOT.mkdir(parents=True, exist_ok=True)
    TEST_RUNTIME.mkdir(parents=True, exist_ok=True)
    runtime_parser = TEST_RUNTIME / "parse_ae_project.jsx"
    runtime_parser.write_text(_read_text(PARSER_PATH), encoding="utf-8")

    result = subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(RUNNER_PATH),
            "-MaterialRoot",
            str(EMPTY_MATERIAL_ROOT),
            "-OutputRoot",
            str(TEST_RUNTIME),
            "-AfterFXPath",
            str(TEST_RUNTIME / "missing_AfterFX.exe"),
        ],
        cwd=PROJECT_ROOT,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr + result.stdout

    inventory_path = TEST_RUNTIME / "template_inventory.json"
    markdown_path = TEST_RUNTIME / "template_inventory.md"
    assert inventory_path.exists()
    assert markdown_path.exists()

    inventory = json.loads(_read_text(inventory_path))
    assert inventory["status"] == "no_templates_found"
    assert inventory["afterEffectsOpened"] is False
    assert inventory["afterEffectsExe"] is None
    assert inventory["templateCount"] == 0
    assert inventory["templates"] == []
    assert inventory["logs"]["aeStdout"] is None
    assert inventory["logs"]["aeStderr"] is None

    markdown = _read_text(markdown_path)
    assert "No `.aep` templates were found under the current material root." in markdown
    assert "The JSX parser is ready for future .aep files but was not invoked in this run." in "\n".join(
        inventory["limitations"]
    )


def test_runner_reports_missing_parser_before_scanning_or_launching_afterfx():
    runner = _read_text(RUNNER_PATH)
    parser_guard = runner.index("if (-not (Test-Path -LiteralPath $parserPath))")
    scan_index = runner.index("$aepFiles = @(")
    launch_index = runner.index("Start-Process -FilePath $afterFX")
    catch_index = runner.index("catch {")

    assert parser_guard < scan_index < launch_index
    assert "throw \"Parser JSX is missing: $parserPath\"" in runner[parser_guard:scan_index]
    assert "status = 'runner_error'" in runner[catch_index:]
    assert "exit 1" in runner[catch_index:]


def test_timeout_failure_branch_records_modal_or_blocked_startup_risk():
    runner = _read_text(RUNNER_PATH)
    branch = runner[
        runner.index("if (-not $completed)") : runner.index("Write-Log \"AfterFX exited with code")
    ]

    assert "not_parsed_afterfx_timeout" in branch
    assert "afterfx_timeout" in branch
    assert "Modal prompt or blocked startup is possible." in branch
    assert "licensing dialog" in branch
    assert "Only working copies were opened or targeted." in branch
    assert "Source .aep files were not saved or rendered." in branch
