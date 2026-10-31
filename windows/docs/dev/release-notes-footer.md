## Downloads

| File | Pick it when |
|------|--------------|
| `LCT-v{{VERSION}}-Setup.exe` | **Recommended.** Installer for x64 PCs; bundles the .NET runtime and the Visual C++ redistributable. |
| `LiveCaptionsTranslator-{{VERSION}}-win-x64-withruntime.exe` | Portable, nothing to install, .NET runtime included. |
| `LiveCaptionsTranslator-{{VERSION}}-win-x64.exe` | Portable and smaller; needs the [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0). |
| `LiveCaptionsTranslator-{{VERSION}}-win-arm64-withruntime.exe` | Portable for ARM64 PCs (Snapdragon), runtime included. |
| `LiveCaptionsTranslator-{{VERSION}}-win-arm64.exe` | Portable for ARM64 PCs; needs the .NET 8 Desktop Runtime. |
| `SHA256SUMS.txt` | Checksums of the files above. |

## Requirements

- Windows 11 22H2 or later with **Live Captions** available (Settings ▸ Accessibility ▸ Captions). Turn Live Captions on once and let it download its language pack before starting LCT; the [setup guide](https://github.com/PCcoding666/LCT/blob/master/windows/README.md) walks through it.
- An internet connection on first launch: LCT downloads a local Ollama engine and the default translation model. After that, translation runs fully on your PC.
- 8 GB of RAM or more recommended.

## Known limitations

- The binaries are not code-signed yet, so Windows SmartScreen may show "Windows protected your PC". Choose **More info ▸ Run anyway**. If in doubt, compare the file's SHA-256 with `SHA256SUMS.txt`.
- The installer is x64 only; on ARM64 PCs use the portable ARM64 build.
