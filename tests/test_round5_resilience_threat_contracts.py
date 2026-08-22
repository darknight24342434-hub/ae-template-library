import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def test_runner_excludes_own_output_logs_from_material_scan():
    scan_match = re.search(
        r"Get-ChildItem\s+-LiteralPath\s+\$materialRootResolved\s+-Recurse\s+-File\s+-Filter\s+'\*\.aep'",
        RUNNER,
    )

    assert scan_match, "recursive .aep scan was not found"
    scan_to_copy = RUNNER[scan_match.start() : RUNNER.index("Copy-Item -LiteralPath $file.FullName")]
    assert "working_copies" in scan_to_copy or "$logsRoot" in scan_to_copy
    assert "-notmatch" in scan_to_copy or "Where-Object" in scan_to_copy


def test_timeout_seconds_has_positive_lower_bound_before_waitforexit():
    wait_index = RUNNER.index("$process.WaitForExit($TimeoutSeconds * 1000)")
    before_wait = RUNNER[:wait_index]

    assert re.search(r"\$TimeoutSeconds\s+-le\s+0|\$TimeoutSeconds\s+-lt\s+1", before_wait)
    assert "throw" in before_wait[before_wait.rfind("$TimeoutSeconds") :]


def test_runner_redacts_sensitive_paths_and_text_before_public_inventory():
    sensitive_markers = ("token", "secret", "password", "credential", "redact")
    inventory_region = RUNNER[RUNNER.index("$inventoryJsonPath") :]

    assert any(marker in inventory_region.lower() for marker in sensitive_markers)
    assert "sourcePath" not in inventory_region or "redact" in inventory_region.lower()
    assert "workingCopyPath" not in inventory_region or "redact" in inventory_region.lower()


def test_jsx_redacts_text_layer_contents_and_file_paths():
    sensitive_fields = ("text: textInfo.text", "filePath: filePath", "sourcePath: sourcePath")

    for field in sensitive_fields:
        assert field not in JSX
    assert "redact" in JSX.lower()
