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


def test_safe_filename_replaces_invalid_characters_and_has_empty_fallback():
    body = _function_body(RUNNER, "ConvertTo-SafeFileName")

    assert "[System.IO.Path]::GetInvalidFileNameChars()" in body
    assert "$invalid -contains $ch" in body
    assert "[void]$builder.Append('_')" in body
    assert "$builder.ToString().Trim()" in body
    assert "[string]::IsNullOrWhiteSpace($safe)" in body
    assert "return 'template.aep'" in body


def test_jsx_string_literal_escapes_path_control_characters_before_wrapper_eval():
    literal_body = _function_body(RUNNER, "ConvertTo-JsxStringLiteral")
    wrapper_region = RUNNER[RUNNER.index("$wrapperLines = @(") : RUNNER.index("Set-Content -LiteralPath $jsxWrapperPath")]

    for escaped_fragment in (".Replace('\\', '\\\\')", ".Replace('\"', '\\\"')", ".Replace(\"`r\", '\\r')", ".Replace(\"`n\", '\\n')"):
        assert escaped_fragment in literal_body
    assert "AE_TEMPLATE_PARSE_CONFIG = ' + (ConvertTo-JsxStringLiteral -Value $aeConfigJsonPath)" in wrapper_region
    assert "$.evalFile(File(' + (ConvertTo-JsxStringLiteral -Value $parserPath)" in wrapper_region


def test_markdown_empty_inventory_branch_documents_no_template_failure_path():
    markdown_body = _function_body(RUNNER, "New-InventoryMarkdown")

    assert "$templates = @($Inventory.templates)" in markdown_body
    assert "if ($templates.Count -eq 0)" in markdown_body
    assert "No `.aep` templates were found under the current material root." in markdown_body
    assert "The JSX parser is ready for future .aep files but was not invoked in this run." in RUNNER


def test_json_writer_uses_explicit_utf8_and_deep_serialisation():
    body = _function_body(RUNNER, "Write-JsonFile")

    assert "[int]$Depth = 80" in RUNNER
    assert "ConvertTo-Json -Depth $Depth" in body
    assert "Set-Content -LiteralPath $Path -Value $json -Encoding UTF8" in body


def test_jsx_to_json_handles_non_finite_numbers_and_own_properties_only():
    body = _function_body(JSX, "toJson")

    assert "return isFinite(value) ? String(value) : 'null';" in body
    assert "value instanceof Array" in body
    assert "value.hasOwnProperty(key)" in body
    assert "quoteJsonString(key) + ':' + toJson(value[key])" in body


def test_jsx_template_missing_working_copy_is_explicit_template_error():
    scan_body = _function_body(JSX, "scanProject")
    parse_loop_region = JSX[JSX.index("for (var i = 0; i < config.templates.length; i++)") :]

    assert "if (!projectFile.exists)" in scan_body
    assert "throw new Error('Working copy does not exist: ' + templateConfig.workingCopyPath);" in scan_body
    assert "catch (templateError)" in parse_loop_region
    assert "status: 'error'" in parse_loop_region
    assert "error: String(templateError)" in parse_loop_region
