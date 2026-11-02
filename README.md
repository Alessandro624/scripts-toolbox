# Scripts Toolbox

Small, independent command-line tools for PDF processing, Windows disk-usage
audits, Microsoft Teams membership, and file timestamps.

| Script | Purpose | Requirements |
| --- | --- | --- |
| `compress_pdf.sh` | Compress copies of PDFs | Bash 4.4+, GNU utilities, Ghostscript |
| `merge_pdfs.sh` | Merge PDFs by filename group | Bash 4.4+, GNU utilities, Poppler or Ghostscript |
| `extract_exercises.py` | Extract whole exercise pages by chapter | Python 3.10+, dependencies in `requirements.txt` |
| `PC-Maintenance-Audit.ps1` | Report disk usage and changes | Windows, PowerShell 5.1 or 7, Storage module |
| `PC-Maintenance-Dispatcher.ps1` | Select the scheduled audit mode | Same as the audit |
| `update_file_timestamp_for_ftp.php` | Set a local file's modification time | PHP 8.1+ |
| `remove-me-from-this-team.ps1` | Leave a team as the signed-in user | PowerShell 5.1 or 7, MicrosoftTeams module |

## Quick start

### PDFs

Run from Linux or Git Bash:

```bash
bash compress_pdf.sh /path/to/pdfs
bash compress_pdf.sh /path/to/pdfs /path/to/results printer
bash merge_pdfs.sh /path/to/pdfs
```

Defaults are the current input directory, `compressed/` or `merged/` underneath
it, and the `ebook` compression preset. Use `--help` for argument order.
Only top-level lowercase `*.pdf` files are processed.

Merge groups use `NUMBER-TITLE[-PART].pdf`. For example, `01-Intro-2.pdf` and
`01-Intro-10.pdf` become `merged/01-Intro.pdf`, in natural filename order.
`01-Other-1.pdf` becomes a separate `01-Other.pdf`. The title is the segment
between the first and second hyphens; additional hyphens describe the part.

Compression can reduce visual quality, invalidate signatures, and occasionally increase size. Review the copies.

### Exercise extraction

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate
# Linux/macOS: source .venv/bin/activate
python -m pip install -r requirements.txt
python extract_exercises.py textbook.pdf --output-dir exercises_output
```

Use `--help` for optional arguments. Originals are retained and outputs are
written to separate directories.

### Windows maintenance

```powershell
.\PC-Maintenance-Audit.ps1 -Mode Monthly
.\PC-Maintenance-Audit.ps1 -Mode Quarterly -ProjectRoots 'C:\Projects' -OutputDirectory 'D:\Audit'
.\PC-Maintenance-Dispatcher.ps1 -DryRun
```

No project path is stored in the script. Pass one or more local roots explicitly
with `-ProjectRoots`; missing roots are ignored. Reports and snapshots default to
`$HOME\Documents\PC-Maintenance`, with dispatcher logs in `logs`.

The audit supports `Monthly`, `Quarterly` and `Full` modes. The dispatcher selects
the mode on the first day of the month (March/September: Quarterly,
June/December: Full, otherwise Monthly). It does not register scheduled tasks.

Discovery is fresh by default. `-ReuseInventory` on the audit opts into the faster
Monthly mode, which can miss newly created directories. Baselines must match the
schema, mode, computer name and project roots.

Measurements are best-effort, not a complete filesystem accounting system.
Unreadable directory/allocated-size measurements generate warnings and a
`MeasurementWarnings` count. Known VHDX locations are not exhaustive. Some optional
collectors skip inaccessible or unavailable resources. Full directory totals
overlap and must not be summed. Fields named `GB` retain the existing API naming
but use GiB (1024³ bytes).

### File timestamps

```bash
php update_file_timestamp_for_ftp.php ./example.txt '2026-04-07 22:19:24' Europe/Rome
```

The date and file are required, and the default timezone is `Europe/Rome`.
Invalid dates are rejected. The tool preserves file contents and access time and
checks the resulting modification time. It does not set creation time.

For HTTP use, configure `TIMESTAMP_TOKEN` and `TIMESTAMP_DIRECTORY` in the
server environment. Keep the token outside source control.

### Microsoft Teams

```powershell
Install-Module MicrosoftTeams -Scope CurrentUser
.\remove-me-from-this-team.ps1 -TeamName 'Example team' -WhatIf
.\remove-me-from-this-team.ps1 -TeamName 'Example team'
# Use the ID when multiple teams share the same display name:
.\remove-me-from-this-team.ps1 -GroupId '11111111-1111-1111-1111-111111111111'
```

The script signs in interactively, selects an exact team membership, and asks for
confirmation before removing the signed-in account.

`-WhatIf` previews the exact membership. Use `-GroupId` when names are
ambiguous.

Removal also affects the Microsoft 365 group behind the team, and the Teams UI
can take time to update. See Microsoft's
[Remove-TeamUser documentation](https://learn.microsoft.com/en-us/powershell/module/microsoftteams/remove-teamuser?view=teams-ps).

## Tests

```bash
python -m unittest discover -s tests -v
bash tests/test_shell.sh
shellcheck compress_pdf.sh merge_pdfs.sh tests/test_shell.sh
php -l update_file_timestamp_for_ftp.php
```

```powershell
.\tests\test_powershell.ps1
.\tests\test_teams.ps1
```
