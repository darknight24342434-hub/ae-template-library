import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def test_parser_path_is_resolved_from_runner_location_not_output_root():
    assert "$scriptRoot" in RUNNER or "Split-Path -Parent $PSCommandPath" in RUNNER
    assert "$parserPath = Join-Path $OutputRoot 'parse_ae_project.jsx'" not in RUNNER


def test_default_material_root_is_not_a_hardcoded_absolute_path():
    """The default material root must not be a path on whoever wrote this.

    This contract originally required the default to *be* one specific absolute
    directory on the author's machine. That is the opposite of what a portable tool
    wants, so it now asserts the default is resolved at runtime instead — and still
    guards against the mojibake that a previous encoding accident left in it.
    """
    match = re.search(r"\[string\]\$MaterialRoot\s*=\s*(.+?),\s*$", RUNNER, re.M)

    assert match, "MaterialRoot default parameter was not found"
    default_expr = match.group(1).strip()

    assert not re.match(r"^'[A-Za-z]:", default_expr), f"drive-letter path baked in: {default_expr}"
    assert not default_expr.startswith("'\\\\"), f"UNC path baked in: {default_expr}"
    assert "?" not in default_expr
    assert "撠" not in default_expr


def test_afterfx_parser_status_is_correlated_before_inventory_success():
    assert "$aeStatusJsonPath" in RUNNER
    assert "ConvertFrom-Json" in RUNNER
    assert re.search(r"Get-Content\s+-LiteralPath\s+\$aeStatusJsonPath", RUNNER)
    assert re.search(r"\.stage\s+-eq\s+'ok'|stage\s*=\s*'ok'", RUNNER)


def test_jsx_project_close_is_guarded_when_open_fails():
    open_index = JSX.index("app.open(projectFile);")
    close_index = JSX.index("app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);")

    assert close_index < open_index or "finally" in JSX[open_index:close_index]
