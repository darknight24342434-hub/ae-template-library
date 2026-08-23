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
| `-OutputRoot` | the script's own folder | Where the inventory and `logs/` go. Must be the script's folder or a subfolder of it unless `-AllowOutputOutsideProject` is given, and must never be inside `-MaterialRoot`. |
| `-MaxTemplates` | `200` | Stop enumerating after this many `.aep` files. The recursive scan is not sorted, so on a huge tree this bounds both time and memory; the run log says when the limit was hit. |
| `-IncludeLayerDetails` | off | Record every layer of every comp in the per-template detail file. Off, only counts are recorded. |
| `-MaxLayersPerComp` | `200` | With `-IncludeLayerDetails`, the ceiling per comp; layers past it are counted, not stored. |
| `-TimeoutSeconds` | `300` | How long to wait for After Effects. Must be between 1 and 86400. |
| `-AllowExistingAE` | off | Reuse an After Effects that is already running. The parser then leaves that session open instead of quitting it, and waits for its own status file rather than for the process to exit. |
| `-AllowOutputOutsideProject` | off | Permit an `-OutputRoot` outside the script's folder. |
| `-AdobeSearchRoot` | — | An extra directory to search for `AfterFX.exe`, if After Effects is not under `C:\Program Files\Adobe`. |
| `-AfterFXPath` | — | Use this exact `AfterFX.exe`. |

`AE_SEARCH_ROOTS` does the same as `-AdobeSearchRoot` and accepts several paths separated by `;`.

The scanner tries After Effects 2026, 2025 and 2024 in that order under each search root.

**Scanning the folder the script is in will be refused**, because the output — working copies, logs — would then be inside the tree being scanned and every run would find the previous one's copies. Point `-MaterialRoot` somewhere else.

## Output

| File | Contents |
| --- | --- |
| `template_inventory.json` | The inventory: run status, material root, and per-template *summaries* — counts, ranked candidate render comps, status, a reference to the detail file. |
| `template_inventory.md` | The same run rendered for a human, including the exact command to repeat it. |
| `logs/scan_<id>/templates/NNN_<name>.json` | One file per template with the full detail: comps, footage, text layers, media slots, nested-comp links. Written the moment each template is parsed, so the batch never holds every project in memory. |
| `logs/scan_<id>/scan.log` | Timestamped run log. |
| `logs/scan_<id>/status.json` | Terminal state for that run. |
| `logs/scan_<id>/ae_status.json` | What the parser itself reported. The runner only trusts the output when this says `ok`, regardless of how After Effects exited. |

The run id is `<timestamp>_<pid>_<6 hex>`, so two runs starting in the same second cannot collide. All of this is gitignored.

### What the inventory does and does not contain

The inventory is meant to be handed around, so the things that would identify a client's material are reduced before they are written:

- **Template paths** are recorded relative to `-MaterialRoot`, plus a 12-character SHA-256 of the absolute path so records from different runs can be matched. The absolute path itself is never written, and never reaches the parser.
- **Footage paths** are reduced to file name plus hash.
- **Text-layer contents** are reduced to length, hash and *shape* — every non-space character replaced by `*`, so `Your Title Here` becomes `**** ***** ****`. The words themselves are not written anywhere.

What it *does* contain: the material root and output root you passed in, the path of the script, and the run's own log paths. Those are the operator's, not the material's.

## Tests

```
python -m pytest
```

59 tests, all passing. They are static contracts over the runner and parser source — confinement of every written path to the run directory, no `eval`, bounded timeout and template counts, redaction, file handles closed in `finally`, the host quit only when the runner launched it — plus one that actually runs the scanner against an empty directory without After Effects.

Three of them read `template_inventory.json` from the project root. On a fresh clone that file does not exist, so a fixture generates it by running the scanner once against an empty temporary directory. That needs Windows PowerShell, which is the only platform the tool runs on anyway.

The contracts were written as a specification ahead of the implementation, and for a long time about half of them failed. They were made to pass before this repository was published; two older assertions that had been superseded by later rounds (an unconditional `app.quit()`, and all results accumulated into one output object) were updated to match the newer contracts rather than left contradicting them.

## Limitations

- **Windows and After Effects only.** There is no way to run this without a licensed AE installation; the parser is ExtendScript executed by the host application.
- **Opening a project launches After Effects.** A scan over many templates is slow and takes over the application while it runs.
- **The parser reads structure, not content.** It does not render, does not evaluate expressions, and does not resolve missing footage.
- **`-MaxTemplates` selects in filesystem enumeration order**, not alphabetically. Which 200 of 300 files you get is whatever the directory walk hands back first; raise the limit rather than relying on the order.
- **Redaction is one-way.** If you need the actual text of a text layer, or the absolute path of a footage item, open the project; the inventory will not give it back.
- **The parser's JSON fallback is a strict parser written by hand.** When the host provides `JSON.parse` it is used; otherwise a small recursive-descent parser takes over. It has been checked against the native parser, but it is still hand-written code on the path that reads the runner's config.

## License

MIT. See [LICENSE](LICENSE).
