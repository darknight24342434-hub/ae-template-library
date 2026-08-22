import re
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNNER = (PROJECT_ROOT / "scan_ae_templates.ps1").read_text(encoding="utf-8-sig")
JSX = (PROJECT_ROOT / "parse_ae_project.jsx").read_text(encoding="utf-8-sig")


def _after(source, marker):
    assert marker in source, f"marker not found: {marker}"
    return source[source.index(marker) :]


def test_runner_exposes_a_template_limit_before_copying_all_aep_files():
    scan_to_copy = RUNNER[
        RUNNER.index("$aepFiles = @(Get-ChildItem")
        : RUNNER.index("Copy-Item -LiteralPath $file.FullName")
    ]

    assert re.search(r"\b(MaxTemplates|Limit|First)\b", scan_to_copy)
    assert "Select-Object -First" in scan_to_copy


def test_runner_avoids_sorting_entire_recursive_aep_scan_before_processing():
    scan_line = re.search(r"\$aepFiles\s*=\s*@\((.+?)\)", RUNNER, re.DOTALL)

    assert scan_line
    assert "Sort-Object" not in scan_line.group(1)


def test_jsx_parser_does_not_accumulate_every_layer_detail_unconditionally():
    scan_layers_body = JSX[
        JSX.index("function scanCompLayers")
        : JSX.index("function scoreRenderComp")
    ]

    assert "IncludeLayerDetails" in JSX or "MaxLayers" in JSX
    assert "compInfo.layers.push(layerInfo)" not in scan_layers_body


def test_jsx_parser_streams_template_results_instead_of_one_large_output_object():
    parse_loop = _after(JSX, "for (var i = 0; i < config.templates.length; i++)")

    assert "output.templates.push(scanProject(templateConfig))" not in parse_loop
    assert re.search(r"write(Text)?\(.+template", parse_loop, re.IGNORECASE)
