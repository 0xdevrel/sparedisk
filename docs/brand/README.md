# SpareDisk identity assets

Created September 12, 2026 with the built-in imagegen tool (builtin mode). No external API or API key was used. The generated raster was inspected and proportionally resampled with macOS `sips` for standard app-icon packaging; no creative image editing was done outside imagegen.

- `SpareDisk-Icon.png`: 1024×1024 RGBA master.
- `Original-AppIcon.png`: backup of the app's previous 1024px icon.
- Production assets: `SpareDisk/Sparedisk.icon` (layered Icon Composer source, compiled at build time) and `SpareDiskLogo.imageset` (in-app logo). The flattened `AppIcon.appiconset` was retired once the `.icon` source shipped.

The pale disk, teal spare sector and midnight-blue tile express the product's storage purpose without letters or tiny symbols. Use the master as source; avoid repeatedly resizing small outputs. The art is raster, not a vector or layered Icon Composer source.

## Exact generation prompt

> Use case: logo-brand. Asset type: production macOS application icon and identity for SpareDisk, a native storage analysis utility. Create ONE square 1024x1024 app icon, not a mockup or presentation board. A beautifully restrained, geometric disk glyph: a thick circular ring, a clean open wedge at upper right, and one small matching detached rounded sector positioned just outward in that opening, expressing spare storage space. Disk ring in pale cool white, detached sector in clear sea-glass teal. Center has a small dark circular spindle opening, integrated into the simple disk form. Centered on a rich deep midnight-blue rounded-square macOS icon tile, with very subtle dimensional lighting, crisp precise geometry, and generous balanced internal spacing. Tile inset around 9% of canvas on all sides, genuinely transparent outside the rounded tile, no outer drop shadow. No letters, words, text, numbers, badge, chart ticks, gradients in the glyph, extra shapes, metallic hard-drive illustration, sparkles, or Apple logo. The silhouette should remain exceptionally recognizable at 16 and 32 pixels. Premium native Mac utility, calm, high contrast, precise optical balance. Single finished icon only.

## Maintenance

AppIcon `Contents.json` historically contained ten macOS entries. The named in-app logo uses 128px and 256px files. Keep `ASSETCATALOG_COMPILER_APPICON_NAME = Sparedisk` while the `.icon` source is the app icon. A new Xcode build/relaunch is required to see asset changes; an older running app may retain its previous icon.
