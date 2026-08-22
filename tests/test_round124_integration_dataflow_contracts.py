import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def test_allow_existing_ae_does_not_unconditionally_quit_host_application():
    existing_ae_region = RUNNER[
        RUNNER.index("$existingAe = @(") : RUNNER.index("New-DirectoryIfMissing -Path $workingCopiesDir")
    ]

    assert "-AllowExistingAE" in RUNNER or "$AllowExistingAE" in existing_ae_region
    assert "allowExistingAE" in RUNNER or "allowExistingAE" in JSX
    assert "app.quit();" not in JSX


def test_run_directory_uses_collision_resistant_identifier_before_writing_status():
    run_id_region = RUNNER[
        RUNNER.index("$runId =") : RUNNER.index("$scanLogPath = Join-Path $runDir")
    ]

    assert "yyyyMMdd_HHmmss" not in run_id_region
    assert re.search(r"NewGuid|Guid|HHmmssfff|PID|\$PID", run_id_region)


def test_parser_output_and_status_paths_are_validated_against_run_directory():
    config_region = JSX[JSX.index("var config = parseJson") :]

    assert "config.runDir" in config_region
    assert re.search(r"outputJsonPath.*runDir|runDir.*outputJsonPath", config_region, re.DOTALL)
    assert re.search(r"statusJsonPath.*runDir|runDir.*statusJsonPath", config_region, re.DOTALL)
    assert re.search(r"\\.json", config_region)
