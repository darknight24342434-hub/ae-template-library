import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def test_jsx_config_parser_does_not_fall_back_to_eval():
    parse_json_body = JSX[JSX.index("function parseJson") : JSX.index("function quoteJsonString")]

    assert "JSON.parse(text)" in parse_json_body
    assert "eval(" not in parse_json_body


def test_jsx_output_paths_are_validated_inside_run_directory_before_write():
    config_region = JSX[JSX.index("var config = parseJson") :]
    first_write_index = min(
        config_region.index("writeText(config.outputJsonPath"),
        config_region.index("writeText(config.statusJsonPath"),
    )
    before_first_write = config_region[:first_write_index]

    assert "config.runDir" in before_first_write
    assert re.search(r"outputJsonPath.*runDir|runDir.*outputJsonPath", before_first_write, re.DOTALL)
    assert re.search(r"statusJsonPath.*runDir|runDir.*statusJsonPath", before_first_write, re.DOTALL)
    assert re.search(r"throw\s+new\s+Error", before_first_write)
