# Repository instructions

- Read `README.md` before changing user-visible behavior.
- Read `docs/ARCHITECTURE.md` before changing window identity, input-profile discovery, rules, persistence, polling, Win32/TSF/IMM calls, startup, or migration.
- Read `CONTRIBUTING.md` before changing the build or tests.
- Read `docs/RELEASING.md` and `CHANGELOG.md` before changing versions, tags, packages, or release notes.
- Product identity, artifact names, author details, and version metadata belong in `lib/AppInfo.ahk`.
- User-editable settings and rules belong in `config.ini`; learned window state belongs in `state.ini`.
- Do not commit runtime configuration, state, logs, build output, machine-specific paths, or secrets.
- Run the full PowerShell 7 build before handing off code changes:

  ```powershell
  pwsh -NoProfile -File .\build.ps1
  ```

- Do not bump the version or create a tag unless the task explicitly requests a release.
