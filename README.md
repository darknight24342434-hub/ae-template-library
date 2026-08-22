# ae-template-library

A scanner that walks a folder tree of After Effects projects, opens each one through `aerender`'s host application with an ExtendScript parser, and writes an inventory of what is inside them — compositions, their settings, and the layers you would actually swap when reusing the project as a template.

## What it does / why

A folder of `.aep` files tells you nothing about what is in them. Which of these is 1920×1080? Which has a text layer you can retitle? Which expects three image placeholders? Answering that means opening each project by hand.

`scan_ae_templates.ps1` does the walk. For each `.aep` it finds it:

1. **Copies the project into the run folder first** and opens the copy, never the original.
2. Launches `AfterFX.exe -r` against `parse_ae_project.jsx`.
3. Lets the parser inventory compositions, dimensions, frame rate, duration, and the editable slots — text layers, footage placeholders.
4. Closes the project with `DO_NOT_SAVE_CHANGES`.
5. Writes `template_inventory.json`, a human-readable `template_inventory.md`, and a timestamped run log.

It never renders, never generates previews, and never writes over a source template. If no `.aep` files are found it still writes an inventory saying so, rather than failing.

## Requirements

- Windows with **After Effects** installed. The scanner locates `AfterFX.exe` under `C:\Program Files\Adobe` by default.
- Windows PowerShell 5.1.
- Python with `pytest`, only to run the test suite.

## Install

```
git clone <repo-url> ae-template-library
cd ae-template-library
```

Nothing to build.

## Usage

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scan_ae_templates.ps1 -MaterialRoot "D:\path\to\your\templates"
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-MaterialRoot` | the current directory | The tree to search recursively for `.aep` files. |
| `-AdobeSearchRoot` | — | An extra directory to search for `AfterFX.exe`, if After Effects is not under `C:\Program Files\Adobe`. |

`AE_SEARCH_ROOTS` does the same as `-AdobeSearchRoot` and accepts several paths separated by `;`.

The scanner tries After Effects 2026, 2025 and 2024 in that order under each search root.

## Output

| File | Contents |
| --- | --- |
| `template_inventory.json` | The machine-readable inventory: run status, material root, per-template composition and layer data. |
| `template_inventory.md` | The same run rendered for a human, including the exact command to repeat it. |
| `logs/scan_<timestamp>/scan.log` | Timestamped run log. |
| `logs/scan_<timestamp>/status.json` | Terminal state for that run. |

All of these are gitignored — see the warning below.

## Read this before sharing an inventory

**The generated inventory is not sanitised.** It records absolute paths from the machine that produced it, and the parser puts text-layer contents and footage paths into the output. If you scan client templates and then hand the inventory to someone, you hand over the script text and the directory layout with it.

This is a known gap, not a surprise: the test suite has explicit contracts named `test_runner_redacts_sensitive_paths_and_text_before_public_inventory` and `test_jsx_redacts_text_layer_contents_and_file_paths`, and both currently fail. Treat any inventory as internal until that changes.

## Tests

```
python -m pytest
```

**About half the suite fails, and always has.** These are contract tests written as a specification of what the scanner and parser *should* do, ahead of the implementation.

On a fresh clone: **28 pass, 31 fail.** Run the scanner once first — four of those failures are tests that read `template_inventory.json`, which does not exist until something generates it — and it becomes **32 pass, 27 fail**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scan_ae_templates.ps1 -MaterialRoot .
python -m pytest
```

That is the honest state of the project, and the failures are the most useful documentation in the repository — each names a specific gap:

| Theme | Failing contracts | What they want |
| --- | --- | --- |
| Config parsing | 4 | The JSX config parser should parse JSON, not fall back to `eval`. |
| Output-path confinement | 5 | Every written path should be validated to stay inside the run directory before the write. |
| Redaction | 2 | Text-layer contents and absolute media paths should be stripped from the public inventory. |
| Timeout handling | 4 | `timeoutSeconds` should be bounded and rejected when non-positive, before the conversion to milliseconds. |
| File handles | 2 | Read and write helpers should close in a `finally` block. |
| Scale | 4 | A template limit, no full sort of a recursive scan before processing, streamed rather than accumulated output. |
| Integration | 6 | Parser path resolved from the runner's location, the host application not quit unconditionally, collision-resistant run directory identifiers, parser status correlated before declaring success. |

The first three groups are security-relevant. Read them as a to-do list.

## Limitations

- **Windows and After Effects only.** There is no way to run this without a licensed AE installation; the parser is ExtendScript executed by the host application.
- **Opening a project launches After Effects.** A scan over many templates is slow and takes over the application while it runs.
- **The parser reads structure, not content.** It does not render, does not evaluate expressions, and does not resolve missing footage.
- **`test_inventory_contract.py` only passes where the inventory was generated.** The shipped repository has no inventory; run the scanner once and those tests have something to check.
- See the redaction warning above before sharing any output.

## License

MIT. See [LICENSE](LICENSE).
