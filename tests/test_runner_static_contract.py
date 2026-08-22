import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")


def test_runner_defines_distinct_failure_statuses_and_exit_codes():
    expected_statuses = {
        "no_templates_found": "0",
        "templates_found_afterfx_not_found": "2",
        "templates_found_existing_ae_process": "3",
        "afterfx_timeout": "4",
        "runner_error": "1",
    }

    for status, exit_code in expected_statuses.items():
        assert f"status = '{status}'" in RUNNER or f"Stage '{status}'" in RUNNER
        assert re.search(rf"exit\s+{exit_code}\b", RUNNER)


def test_runner_copies_templates_before_afterfx_and_documents_source_safety():
    copy_index = RUNNER.index("Copy-Item -LiteralPath $file.FullName -Destination $copyPath")
    launch_index = RUNNER.index("Start-Process -FilePath $afterFX")

    assert copy_index < launch_index
    assert "workingCopyPath" in RUNNER
    assert "Source .aep files were not saved or rendered." in RUNNER
    assert "DO_NOT_SAVE_CHANGES" in RUNNER


def test_runner_timeout_default_is_positive_and_hidden_afterfx_window():
    timeout_match = re.search(r"\[int\]\$TimeoutSeconds\s*=\s*(\d+)", RUNNER)

    assert timeout_match
    assert int(timeout_match.group(1)) > 0
    assert "$process.WaitForExit($TimeoutSeconds * 1000)" in RUNNER
    assert "-WindowStyle Hidden" in RUNNER


def test_runner_generates_required_inventory_fields_in_each_terminal_branch():
    terminal_statuses = [
        "no_templates_found",
        "templates_found_afterfx_not_found",
        "templates_found_existing_ae_process",
        "afterfx_timeout",
        "parsed",
        "partially_parsed",
        "parse_failed",
        "runner_error",
    ]

    for status in terminal_statuses:
        assert status in RUNNER

    for field in (
        "schemaVersion",
        "generatedAt",
        "materialRoot",
        "outputRoot",
        "runnerPath",
        "parserPath",
        "status",
        "afterEffectsOpened",
        "templateCount",
        "templates",
        "logs",
        "limitations",
    ):
        assert field in RUNNER
