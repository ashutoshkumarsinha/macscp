# MacSCP Packaging Guide

Build a signed (or ad-hoc) `MacSCP.app` and `.dmg` installer from the Swift package.

---

## Quick start

```bash
make icon
make package-dmg
open dist/MacSCP-0.1.0.dmg
```

---

## Scripts

| Script | Purpose |
|---|---|
| `scripts/generate-app-icon.sh` | Crop master to square 1024×1024, fill asset catalog, build `.icns` |
| `scripts/package-dmg.sh` | Release build, assemble `.app`, codesign, create DMG |

Makefile targets: `make icon`, `make package-dmg`.

---

## App Icon pipeline

1. **Master:** `Resources/AppIcon/MacSCP-AppIcon-1024.png`
2. **Square crop:** non-square masters are center-cropped (e.g. 1536×1024 → 1024×1024)
3. **Asset catalog:** `packaging/MacSCP.xcassets/AppIcon.appiconset/`
   - `AppIcon-1024.png` → **1024pt slot** (512×512 @2x in Xcode)
   - All standard macOS sizes (16 … 512)
4. **ICNS:** `build/AppIcon.icns` via `iconutil`
5. **Bundle:** copied to `MacSCP.app/Contents/Resources/AppIcon.icns` with `CFBundleIconFile` in Info.plist

Open `packaging/MacSCP.xcassets` in Xcode to preview the App Icon set.

---

## App bundle layout

```text
build/MacSCP.app/
  Contents/
    Info.plist              ← from packaging/Info.plist (version substituted)
    MacOS/MacSCP            ← release binary from swift build -c release
    Resources/
      AppIcon.icns          ← dock / Finder icon
      Assets.car            ← optional, from actool if Xcode CLT available
```

---

## DMG layout

```text
dist/MacSCP-0.1.0.dmg
  MacSCP.app
  Applications → /Applications
```

Created with `hdiutil create -format UDZO`.

---

## Code signing

| Variable | Default | Description |
|---|---|---|
| `MACSCP_SIGN_IDENTITY` | _(empty)_ | e.g. `Developer ID Application: …` |
| `MACSCP_SKIP_SIGN` | `0` | Set to `1` to skip signing entirely |

When identity is set, the script signs the binary and app bundle with `--options runtime` (hardened runtime). The DMG is signed if identity is provided.

Without identity, ad-hoc signing (`codesign -s -`) is attempted for local testing.

---

## Version and bundle ID

| Variable | Default |
|---|---|
| `MACSCP_SHORT_VERSION` | `0.1.0` |
| `MACSCP_BUILD_VERSION` | same as short version |
| `MACSCP_BUNDLE_ID` | `com.macscp.app` |

Example:

```bash
MACSCP_SHORT_VERSION=0.2.0 MACSCP_BUILD_VERSION=42 make package-dmg
```

---

## Requirements

- macOS 15+
- Xcode Command Line Tools (`swift`, `sips`, `iconutil`, `hdiutil`, `codesign`)
- Optional: full Xcode for `actool` (Assets.car compilation)

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `iconutil: Invalid Iconset` | Re-run `make icon`; ensure no extra files in `build/AppIcon.iconset/` |
| App has generic icon | Confirm `AppIcon.icns` exists in `Contents/Resources/` and `CFBundleIconFile` is `AppIcon` |
| Gatekeeper blocks app | Sign with Developer ID + notarize (not yet automated) |

---

*Related: [user-guide.md](user-guide.md), [hld.md](hld.md)*
