# media/

Visual assets for the project README.

## What's here, and how it's maintained

Two kinds of asset, deliberately kept separate so updates stay cheap:

### Diagrams & mockups — `*.svg` (authored here, low-churn)

`banner.svg`, `isolated-profile.svg`, `whats-inside.svg`, and the
`control-*.svg` terminal mockups are **hand-authored SVG that lives in this
repo**. They are text, so they diff cleanly, version with the code, and never
drift from a deck in another repo. Edit them directly.

The `control-*.svg` mockups reproduce the guards' **real** output strings
(from `config/hooks/command-guard.ts`, `leak-guard.ts`, the `permissions.deny`
rules in `config/settings.base.json`, and the `statusline.ts` layout). If you
change a guard's message or the statusline layout, update the matching SVG so
the mockup stays faithful. They are illustrative, not screen captures.

Palette is the AKA design system: coal `#232F3E`, green `#00E0B8`, cyan
`#6AD9FF`, lavender `#8A98FF`, red `#F76F68`. Fonts use system fallbacks
(`system-ui`, `ui-monospace`) because GitHub sandboxes README SVGs — no
external webfonts load.

### Full carousel decks — `decks/*.pdf` (snapshots, refresh on demand)

`decks/whats-inside.pdf` and `decks/safe-setup.pdf` are **point-in-time
snapshots** of the public-facing LinkedIn decks. Their source lives in the
internal docs workspace, not here, so these copies are *not* a live mirror —
they are refreshed manually when the decks change materially:

```
# from the internal docs workspace (aka/internaldocs/social):
( cd 2026-06-22-aka-claude-tools-whats-inside && ./export.sh )
( cd 2026-06-22-aka-claude-tools-safe-setup  && ./export.sh )
# then copy the rendered PDFs over the two files in media/decks/
```

Only the **public-safe** decks are mirrored here (product tour + onboarding).
The internal "stack / field notes" deck is **not** published — it carries
fleet-internal detail. Keep it that way: don't add it.

A small typo fix in a deck does **not** need a re-sync — only refresh when the
content has changed enough that a stale snapshot would mislead.
