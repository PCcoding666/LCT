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

- Windows 10 version 1809 or later, or Windows 11 (x64 or ARM64). Live Captions is **not** needed any more.
- [Ollama for Windows](https://ollama.com/download/windows) for translation. LCT uses an Ollama you already have; the first-run wizard helps you install one, or connect to a remote Ollama server over HTTPS.
- An internet connection on first launch to download the translation model (about 1–3 GB) and the speech-recognition model (about 150–500 MB). After that everything runs on your PC.
- 8 GB of RAM or more recommended; 16 GB or a GPU with 6 GB+ of memory for the 4B translation model.

## Known limitations

- The binaries are not code-signed yet, so Windows SmartScreen may show "Windows protected your PC". Choose **More info ▸ Run anyway**. If in doubt, compare the file's SHA-256 with `SHA256SUMS.txt`.
- The installer is x64 only; on ARM64 PCs use the portable ARM64 build.
