import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def _function_body(source, name):
    match = re.search(rf"function {name}\([^)]*\) \{{", source)
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


def test_jsx_json_config_parser_does_not_execute_config_text():
    parse_json_body = _function_body(JSX, "parseJson")

    assert "eval(" not in parse_json_body
    assert "JSON.parse(text)" in parse_json_body


def test_jsx_file_helpers_close_handles_on_read_write_errors():
    for helper in ("readText", "writeText"):
        body = _function_body(JSX, helper)
        assert "finally" in body
        assert "file.close()" in body


def test_runner_rejects_non_positive_timeout_before_waitforexit():
    wait_index = RUNNER.index("$process.WaitForExit($TimeoutSeconds * 1000)")
    before_wait = RUNNER[:wait_index]

    assert re.search(r"\$TimeoutSeconds\s+-l[et]\s+0|\$TimeoutSeconds\s+-lt\s+1", before_wait)
    assert re.search(r"throw\s+.*TimeoutSeconds", before_wait, re.IGNORECASE)


def test_runner_restricts_output_root_to_project_root_by_default_contract():
    output_resolution = RUNNER[RUNNER.index("New-DirectoryIfMissing -Path $OutputRoot") : RUNNER.index("$runnerPath")]

    assert "$PSScriptRoot" in output_resolution
    assert re.search(r"throw\s+.*OutputRoot", output_resolution, re.IGNORECASE)
    assert re.search(r"StartsWith|IsSubPathOf|GetRelativePath", output_resolution)
