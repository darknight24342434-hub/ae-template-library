import json
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def load_inventory():
    with (PROJECT_ROOT / "template_inventory.json").open(encoding="utf-8-sig") as handle:
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
