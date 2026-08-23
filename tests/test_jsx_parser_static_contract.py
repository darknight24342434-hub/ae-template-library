import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def extract_function_body(name):
    match = re.search(rf"function {name}\([^)]*\) \{{", JSX)
    assert match, f"function {name} not found"
    start = match.end()
    depth = 1
    index = start
    while index < len(JSX) and depth:
        char = JSX[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        index += 1
    assert depth == 0, f"function {name} body did not close"
    return JSX[start : index - 1]


def test_json_string_writer_escapes_control_characters_and_quotes():
    body = extract_function_body("quoteJsonString")

    for pattern in (r"/\\/g", r'/"/g', r"/\r/g", r"/\n/g", r"/\t/g"):
        assert pattern in body
    assert body.count("s.replace(") == 5
    assert "return '\"' + s + '\"';" in body


def test_parser_records_per_template_errors_without_stopping_batch():
    assert "for (var i = 0; i < config.templates.length; i++)" in JSX
    assert "catch (templateError)" in JSX
    assert "status: 'error'" in JSX
    assert "error: String(templateError)" in JSX
    # Each template is parsed inside the loop and its result streamed to its own
    # file; the batch output carries a summary. (Superseded the older requirement
    # that the full result be pushed onto one output object - see round 8.)
    assert "scanProject(templateConfig" in JSX
    assert "summarizeTemplate(templateResult" in JSX


def test_parser_closes_projects_without_saving_on_success_and_error():
    assert JSX.count("CloseOptions.DO_NOT_SAVE_CHANGES") >= 2
    assert "app.project.close(CloseOptions.DO_NOT_SAVE_CHANGES);" in JSX
    assert "finally {" in JSX
    assert "app.endSuppressDialogs(false);" in JSX
    # The host is quit only when the runner launched it; a reused session is left
    # open. (Superseded the older requirement of an unconditional quit - round 124.)
    assert "releaseHostApplication(config)" in JSX
    assert re.search(r"allowExistingAE[\s\S]{0,300}app\.quit\(\)", JSX)


def test_render_comp_scoring_is_deterministic_for_ties():
    assert "candidates.sort(function (a, b)" in JSX
    assert "if (b.score !== a.score)" in JSX
    assert "return b.score - a.score;" in JSX
    assert "String(a.name).toLowerCase() < String(b.name).toLowerCase() ? -1 : 1" in JSX


def test_required_config_missing_is_explicit_failure():
    assert "var configPath = $.global.AE_TEMPLATE_PARSE_CONFIG;" in JSX
    assert "throw new Error('AE_TEMPLATE_PARSE_CONFIG was not set by the runner wrapper.');" in JSX
