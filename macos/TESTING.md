# LCT macOS validation

Build/unit tests and real audio/GUI acceptance are separate evidence.

## Automated checks

```bash
cd macos
./Scripts/run_tests.sh
```

This runs debug, release, warnings-as-errors, and XCTest. Tests must use fake
speech/capture and isolated settings stores; no unit test may request TCC,
record a microphone, start an external model server, or download large weights.

Key behavior: source captions without a translation engine; source-only export;
pause/resume preserving the session; system-only mode without a microphone;
translation failure/download cancellation preserving captions; generation
cancellation and stale-token isolation; verified/atomic model installation.

## Clean-install GUI and audio matrix

Use `Scripts/dev-run.sh` to package and sign. Never run the raw executable.
Before resetting application state, preserve any user history/settings and
identify exact paths. Removing a shared model service or weights requires the
user's explicit authorization. Reset only `com.lct.mac` permissions.

| Scenario | Expected evidence |
| --- | --- |
| No Ollama, no listener on 11434, no LLM weights | Captions start after Apple speech resources and selected-source permissions are ready; no server requests |
| First launch, system audio selected | Microphone is optional; correct speech/source permissions are requested |
| Permission denied or missing speech resources | Specific instruction for the affected permission/language; no translation-service error |
| English video, system audio only | Moving SYS meter and live original captions from the real Core Audio path |
| Microphone / dual source | Correct source badges and recognition language; original audio retained for reproducibility only with consent |
| Pause, resume, stop | No new source text during pause; session retained on resume; stop leaves export available |
| Export TXT/Markdown/SRT | Original text exists even when every translation is empty |
| Model missing/downloading/cancelled/failed | Original captions continue; model state and actionable retry are separate |
| Download, verify, load | Size/progress/cancel shown; only valid weights become installed |
| Enable translation during capture | Existing session is preserved; new captions translate in the same session |
| Model ready, offline | Original captions and local translations work without external services |
| Overlay, language change, relaunch | Visible states stay consistent with capture and translation settings |
| Quit | App-owned runtime and generation stop; unrelated applications untouched |
| Packaged app moved outside build tree | Embedded framework loads and signature verification passes |

Use known spoken fixtures and inspect actual transcript/translation output,
not just exit status. Record OS/chip, source commit, signing type, model hash,
steps, screenshots, logs, timing and outcomes. Report individual cases as
passed, failed, or blocked. Synthetic speaker-to-microphone tests do not prove
independent real conversational sources or long-session stability.

## Distribution validation

A development-signed app is not a production release. A public package needs
Developer ID signing, notarization, stapling, Gatekeeper verification and a
working download link. See [RELEASE.md](RELEASE.md). Do not close all of Issue
#25's acceptance items based on local XCTest or development-app success alone.
