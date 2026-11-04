# Illunis client (example app)

The Flutter phone app of the Illunis example, built on the Inspiratio framework. See `../README.md` for what the
example is and `../../../README.md` for the framework.

```bash
flutter pub get && flutter analyze && flutter test
```

Paths this app expects next to it: `../content/` (the breathwork library, copied into `assets/breath/` by
`tool/sync_breath_content.sh`) and `../moon_assets/` (builds `assets/moon/`). The water renderer is the local
package in `gpu/`.
