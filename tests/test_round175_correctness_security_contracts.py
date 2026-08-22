import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def _function_body(source, name):
    match = re.search(rf"function {re.escape(name)}\([^)]*\) \{{", source)
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


def test_runner_rejects_output_root_inside_material_root_before_recursive_scan():
    scan_index = RUNNER.index(
        "Get-ChildItem -LiteralPath $materialRootResolved -Recurse -File -Filter '*.aep'"
    )
    before_scan = RUNNER[:scan_index]

    assert re.search(r"OutputRoot.*MaterialRoot|MaterialRoot.*OutputRoot", before_scan, re.DOTALL)
    assert re.search(r"throw\s+.*OutputRoot|throw\s+.*MaterialRoot", before_scan, re.IGNORECASE)


def test_runner_bounds_timeout_seconds_before_waitforexit_conversion():
    wait_index = RUNNER.index("$process.WaitForExit($TimeoutSeconds * 1000)")
    before_wait = RUNNER[:wait_index]

    assert re.search(r"\$TimeoutSeconds\s+-lt\s+1|\$TimeoutSeconds\s+-le\s+0", before_wait)
    assert re.search(r"\$TimeoutSeconds\s+-gt\s+\d+|\$TimeoutSeconds\s+-ge\s+\d+", before_wait)
    assert re.search(r"throw\s+.*TimeoutSeconds", before_wait, re.IGNORECASE)


def test_jsx_config_parser_does_not_execute_config_as_code():
    parse_json_body = _function_body(JSX, "parseJson")

    assert "JSON.parse(text)" in parse_json_body
    assert "eval(" not in parse_json_body


def test_jsx_configured_write_paths_are_confined_to_run_directory():
    config_region = JSX[JSX.index("var config = parseJson") :]
    first_write = config_region.index("writeText(config.outputJsonPath")
    before_write = config_region[:first_write]

    assert "config.runDir" in before_write
    assert re.search(r"outputJsonPath.*runDir|runDir.*outputJsonPath", before_write, re.DOTALL)
    assert re.search(r"statusJsonPath.*runDir|runDir.*statusJsonPath", before_write, re.DOTALL)
    assert re.search(r"throw\s+new\s+Error", before_write)


def test_jsx_read_and_write_helpers_close_files_in_finally_blocks():
    for helper in ("readText", "writeText"):
        body = _function_body(JSX, helper)

        assert "finally" in body
        assert "file.close()" in body
