# MacSCP App Icon

| File | Purpose |
|---|---|
| `MacSCP-AppIcon-1024.png` | Master icon (1024×1024 square, auto-cropped by script) |
| `../packaging/MacSCP.xcassets/` | Xcode App Icon asset catalog (all sizes + 1024pt slot) |
| `../build/AppIcon.icns` | Generated `.icns` embedded in `MacSCP.app` |

## Regenerate icons

```bash
make icon
# or
./scripts/generate-app-icon.sh
```

This script:

1. Crops the master to a **center square** if needed
2. Writes `AppIcon-1024.png` into the **1024pt** catalog slot (`512×512 @2x`)
3. Generates all smaller macOS icon sizes
4. Builds `build/AppIcon.icns` via `iconutil`

## Xcode

Open `packaging/MacSCP.xcassets` in Xcode to preview the App Icon set. All PNG slots are populated by `generate-app-icon.sh`.

## DMG packaging

```bash
make package-dmg
```

The DMG script runs icon generation, embeds `AppIcon.icns` in the app bundle, optionally compiles `Assets.car`, and creates `dist/MacSCP-<version>.dmg`.
