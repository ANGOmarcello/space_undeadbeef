# Project guidance

- Read `Documentation/Restoration.md`, `Documentation/Verification.md`, and
  `Documentation/Backend.md` before changing the restored runtime or host.
- Preserve the original game artwork, menus, and behavior. Extend its existing
  visual system for game UI; keep platform adaptations in the native host.
- Use Angelo Cammalleri in author headers for new source files.
- Keep work in clean, responsibility-scoped Git commits. Check the staged diff
  and run `git diff --cached --check` before each commit. Preserve unrelated work.
- Keep build products, caches, test results, logs, and scratch captures outside
  the repository. Follow the standard DerivedData and temporary-directory paths
  used by the project scripts; clean task-owned disposable output afterward.
- Use the Build iOS Apps and Build macOS Apps workflows for their platforms.
  Visually verify user-facing changes. Use the latest iPhone Pro, not Pro Max,
  for iPhone Simulator checks, and target simulator UDIDs explicitly.
- Other development sessions share this Mac. Do not stop their apps, alter their
  settings, or shut down their simulators. Never change an app's name in App Store
  Connect; that is human-only work.
