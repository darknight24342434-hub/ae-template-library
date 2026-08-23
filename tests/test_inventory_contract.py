import json
import subprocess
import tempfile
from pathlib import Path

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
INVENTORY_PATH = PROJECT_ROOT / "template_inventory.json"


@pytest.fixture(scope="module", autouse=True)
def ensure_inventory_exists():
    """These tests read the inventory the runner writes into the project root.

    A fresh clone has none, so when it is missing, run the scanner once against an
    empty material directory. That exercises the real no-templates branch and needs
    neither After Effects nor any .aep file.
    """
    if INVENTORY_PATH.exists():
        return
    with tempfile.TemporaryDirectory(prefix="ae_inventory_empty_") as empty_root:
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(PROJECT_ROOT / "scan_ae_templates.ps1"),
                "-MaterialRoot",
                empty_root,
                "-OutputRoot",
                str(PROJECT_ROOT),
            ],
            cwd=PROJECT_ROOT,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=60,
        )
    if not INVENTORY_PATH.exists():
        pytest.skip(f"could not generate an inventory: {result.stderr or result.stdout}")


def load_inventory():
    with INVENTORY_PATH.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def test_inventory_no_templates_boundary_contract():
    inventory = load_inventory()

    assert inventory["schemaVersion"] == 1
    assert inventory["status"] == "no_templates_found"
    assert inventory["afterEffectsOpened"] is False
    assert inventory["templateCount"] == 0
    assert inventory["templates"] == []
    assert "No .aep files were present" in inventory["limitations"][0]


def test_inventory_paths_stay_within_project_for_existing_run_outputs():
    inventory = load_inventory()
    project_root = PROJECT_ROOT.resolve()

    for key in ("outputRoot", "runnerPath", "parserPath"):
        value = Path(inventory[key]).resolve()
        assert value == project_root or project_root in value.parents

    for key in ("runDir", "scanLog", "statusJson"):
        value = Path(inventory["logs"][key]).resolve()
        assert project_root in value.parents


def test_status_json_matches_inventory_terminal_state():
    inventory = load_inventory()
    status_path = Path(inventory["logs"]["statusJson"])

    with status_path.open(encoding="utf-8-sig") as handle:
        status = json.load(handle)

    assert status["stage"] == inventory["status"]
    assert status["templateCount"] == inventory["templateCount"]
    assert status["afterEffectsOpened"] == inventory["afterEffectsOpened"]
    assert Path(status["inventoryJson"]).resolve() == (PROJECT_ROOT / "template_inventory.json").resolve()
