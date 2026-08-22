import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def test_runner_rejects_outputroot_inside_materialroot_before_recursive_scan():
    scan_index = RUNNER.index(
        "Get-ChildItem -LiteralPath $materialRootResolved -Recurse -File -Filter '*.aep'"
    )
    before_scan = RUNNER[:scan_index]

    assert re.search(r"OutputRoot.*MaterialRoot|MaterialRoot.*OutputRoot", before_scan, re.DOTALL)
    assert re.search(r"throw|exit\s+[1-9]", before_scan)


def test_timeout_seconds_is_bounded_before_waitforexit_millisecond_conversion():
    wait_index = RUNNER.index("$process.WaitForExit($TimeoutSeconds * 1000)")
    before_wait = RUNNER[:wait_index]

    assert re.search(r"TimeoutSeconds\s+-lt\s+1|TimeoutSeconds\s+-le\s+0", before_wait)
    assert re.search(r"TimeoutSeconds\s+-gt\s+\d+|TimeoutSeconds\s+-ge\s+\d+", before_wait)


def test_jsx_restricts_configured_output_paths_to_run_directory():
    config_region = JSX[JSX.index("var config = parseJson") :]
    first_write = config_region.index("writeText(config.outputJsonPath")
    before_write = config_region[:first_write]

    assert "config.runDir" in before_write
    assert re.search(r"outputJsonPath.*runDir|runDir.*outputJsonPath", before_write, re.DOTALL)
    assert re.search(r"statusJsonPath.*runDir|runDir.*statusJsonPath", before_write, re.DOTALL)
    assert re.search(r"throw\s+new\s+Error", before_write)


def test_jsx_public_inventory_avoids_raw_text_and_absolute_media_paths():
    raw_sensitive_fields = (
        "text: textInfo.text",
        "sourcePath: sourcePath",
        "filePath: filePath",
        "sourcePath: templateConfig.sourcePath",
        "workingCopyPath: templateConfig.workingCopyPath",
    )

    for field in raw_sensitive_fields:
        assert field not in JSX
    assert "redact" in JSX.lower() or "hash" in JSX.lower()
