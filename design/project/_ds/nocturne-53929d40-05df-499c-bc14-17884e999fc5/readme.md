# Nocturne design system

Nocturne is a quiet, compact interface on the Catppuccin palette — Mocha by default, Latte as its light theme: a soft near-neutral ground, Inter at medium weight, soft 8px radii and an accent used as a line and a glow rather than a flood. Rules fade to transparent at their ends — over 48px a side — rather than stopping cleanly; short accent marks stay solid. Contrast comes from the tonal ramps, not from saturation, and photographs blend into the page — dark values fall away on Mocha, light values on Latte.

## How to use this

- Link the one stylesheet from every page — `<link rel="stylesheet" href="styles.css">` (adjust the relative path) — and take every color, font, spacing, radius and shadow from its variables (`var(--color-*)`, `var(--font-*)`, `var(--space-*)`, `var(--radius-*)`, `var(--shadow-*)`). Never hard-code a hex, a font name or a px value the tokens already carry.
- Build with the classes below rather than inventing parallel ones; the component pages are plain HTML, so view source and copy the markup.
- `templates/` holds starting points a consuming project can copy whole.
- The whole system was derived from `theme.json`. To change the look, edit the tokens at the top of `styles.css` — every page, the thumbnail and this guide read from them — and keep `theme.json` and the written guidance in step so they don't drift from what the CSS actually does.

## Direction

Left-aligned, asymmetric layouts. Flush-left headings; content hugs the left edge with whitespace on the right. Buttons are outlined (1px accent border on transparent), not solid-filled. In decks, section dividers drop to the mantle ground (the `--color-section` tokens — a step below the page, with a surface1 bloom and an overlay0 ghost), and the landing template's one full-bleed stat band makes the same move at page scale; everywhere else grounds stay desaturated, with soft gradient depth rather than flat fills. Wrap hero and inline images in the `.lighten` class — on Mocha it is `mix-blend-mode: lighten`, so anything darker than the backdrop falls away; on Latte the same class switches to `multiply`, so light values sink into the page instead. Prefer photographs shot on dark backgrounds for Mocha and on light, paper-like backgrounds for Latte.

## Color

Two Catppuccin themes share one token set. **Mocha** is the default and the dark theme (`:root`, and anything under `prefers-color-scheme: dark`); **Latte** is the light theme, applied by `<html data-theme="light">` or by the OS preference when nothing is pinned. Every token below resolves per theme — pages never carry a hex of their own.

| Token | Mocha | Latte |
| --- | --- | --- |
| `--color-bg` | base #1e1e2e | base #eff1f5 |
| `--color-surface` | surface0 #313244 | surface0 #ccd0da |
| `--color-text` | text #cdd6f4 | text #4c4f69 |
| `--color-accent` | mauve #cba6f7 | mauve #8839ef |
| `--color-accent-2` | lavender #b4befe | lavender #7287fd |
| `--color-divider` | surface2 at 60% | surface2 at 60% |
| `--color-section / -glow / -ghost` | mantle · surface1 · overlay0 | mantle · surface1 · overlay0 |
| `--color-danger / -success / -warning` | red · green · yellow | red · green · yellow |
| `--color-scrim` | crust at 65% | text at 40% |

This is still a mono scheme: mauve is the one accent voice, lavender (`--color-accent-2-*`) a near-sibling kept so both sets resolve — treat them as one role. The neutral ramp (`--color-neutral-100…900`) is Catppuccin's own grey steps: on Mocha text → subtext1 → subtext0 → overlay2 → overlay1 → overlay0 → surface2 → surface1 → surface0; on Latte base → mantle → crust → surface0 → surface1 → surface2 → overlay0 → overlay1 → overlay2. The accent ramps are regenerated in OKLCH from each theme's mauve / lavender on a shared lightness scale, with 500 pinned to the accent itself. 100 is the lightest step in both themes — the numbering never flips, only the direction of use does: Mocha tints fills with 700–900 and sets text in 100–300; Latte tints with 100–300 and sets text in 700–900.

So that one mock reads right on both grounds, prefer the **theme-relative roles**, which point at the correct step for the active theme: `--color-accent-fill` (900 ↔ 200), `--color-accent-edge` (700 ↔ 400), `--color-accent-text` (300 ↔ 700 — the paragraph-safe accent), `--color-accent-ink` (200 ↔ 800), `--color-accent-ink-strong` (100 ↔ 900); `--color-neutral-fill` (900 ↔ 400), `--color-neutral-fill-strong` (800 ↔ 500), `--color-neutral-edge` (700 ↔ 600), `--color-neutral-ghost` (600 ↔ 700), `--color-neutral-muted` (500 ↔ 800). Reach for a numbered step only when a value must stay fixed across themes, and for a role before an ad-hoc `color-mix()`.

Status is never faked with the accent or a faded text: `--color-danger` for errors, failed and revoked states, `--color-success` for synced and ready, `--color-warning` for expired, locked and attention. They carry icons, marks, outlines and short labels; running text stays in `--color-text`. Contrast is kept in both themes — text on bg 11.3:1 (Mocha) and 7.1:1 (Latte); accent on bg 8.1:1 and 4.8:1 — but the accent itself is for chrome, icons and large type: paragraph-size accent text uses `--color-accent-text`. For elevation use `--shadow-sm/md/lg` — a hairline edge plus ambient darkness on Mocha, soft ink shadows on Latte — rather than ad-hoc box-shadows. Backdrops behind dialogs and sheets use `--color-scrim`.

## Type

Inter for headings over Inter for body text, loaded as `--font-heading` / `--font-body`. Density 0.70× and radius 8px are already baked into the `--space-*` / `--radius-*` scales — use the variables, not raw numbers.

## Icons

Use Phosphor icons (https://phosphoricons.com) throughout.

## Interaction states

Interactive states are themed, never browser defaults: give every interactive element a `:hover` tint and a pressed state from the accent ramp (one step past the base — `--color-accent-600` on Latte, `--color-accent-400` on Mocha, or a `color-mix()` tint for outlined/ghost variants), and style keyboard focus with `:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 2px; }` — never leave the default blue focus ring.

## Components

| Class | What it is | Shown in |
| --- | --- | --- |
| `.btn` with `.btn-primary`, `.btn-secondary`, `.btn-ghost`, `.btn-icon`, `.btn-block` | Actions — the primary is an accent outline, never a fill | components/buttons.html |
| `.tag` with `.tag-accent`, `.tag-accent-2`, `.tag-neutral`, `.tag-outline`, `.tag-danger`, `.tag-success` | Small labels tinted from the ramps and the status colors (mono palette: accent-2 reads the same as accent) | components/buttons.html |
| `.field` + `label`, `.input`, `.radio` + `.dot`, `.seg` + `.seg-opt` | Form fields and choices on native elements — no script | components/forms.html |
| `.card` with `.card-kicker`, `.card-title`, `.card-body`, `.card-meta`; `.elev-sm/md/lg` | Surface-filled content cards; elevation utilities | components/cards.html |
| `.nav` + `.nav-brand` | The header bar | components/navigation.html |
| `.table` | Data tables with themed header and row rules | components/table.html |
| `.dialog-backdrop` + `.dialog` (+ `.dialog-title/-body/-actions`) | A modal at the top elevation | components/dialog.html |
| `.hr` | A horizontal rule — present, but this system prefers whitespace; avoid it | — |
| `.lighten` | The image wrapper — every content photograph goes through it (lighten on Mocha, multiply on Latte) | foundations/image.html |

States are built in: hovers and pressed states come from the accent ramp, keyboard focus is the 2px accent `:focus-visible` ring, `::selection` is an accent tint, and disabled controls drop to 45% opacity. Don't restyle them per page. The accent-to-ground pair is tuned to at least 3:1 — enough for icons, large text and interface chrome, not for body copy — so for paragraph-size text in the accent use `--color-accent-text` (accent-300 on Mocha, accent-700 on Latte) rather than the accent itself.

## Do

- Keep chroma low outside the accent and the three status colors; lean on the `--color-neutral-*` roles for surfaces, borders and muted text.
- Check both themes — toggle `data-theme` on `<html>` — before calling a screen done.
- Use the compact spacing scale (density 0.7×) — this system is dense on purpose.
- Outline primary actions and let `:focus-visible` carry the accent.
- Put photographs through the `.lighten` wrapper; prefer dark-background subjects for Mocha, light ones for Latte.

## Don't

- Do not flood large areas with the accent, a status color or any saturated fill — the exceptions are the deck section-divider ground and the landing template's stat band (both `--color-section`); the accent carries its chroma in lines and marks, never as a flood.
- Do not use pure black or pure white — every value comes from the ramps. (Shade is the exception, as in the shadow tokens: ambient darkness mixed from black is a shadow, not a color.)
- Do not stack heavy shadows; on Mocha elevation is an edge plus ambient darkness, on Latte a soft ink shadow.
- Do not write a hex into a page — not even for a status or a backdrop; every color resolves through `var(--color-*)`.
- Do not bolden headings past their 500 weight — hierarchy here is size and space.

## Files

- `styles.css` — the only stylesheet: the token sheet (`:root` variables, ramps, base type) plus the component layer. Link it from every page.
- `readme.md` — this guide.
- `theme.json` — the parameters these files were derived from (a machine-readable record of the theme).
- `thumbnail.html` — the project cover (brand mark + swatches).
- `foundations/type.html` — the type scale and the heading/body pairing at real sizes.
- `foundations/color.html` — Mocha and Latte side by side: roles, status colors and the 100-900 tonal ramps, with usage notes.
- `foundations/layout.html` — the spacing scale, the grid and how edges are drawn.
- `foundations/icons.html` — the icon set at interface sizes, inline and in buttons.
- `foundations/image.html` — how photographs and figures are treated.
- `components/buttons.html` — buttons, icon buttons and tags in every variant and state.
- `components/forms.html` — text fields, radios and the segmented control on native elements.
- `components/cards.html` — content cards and the elevation steps.
- `components/navigation.html` — the header bar pattern.
- `components/table.html` — a data table with the themed header and row rules.
- `components/dialog.html` — a modal over its backdrop at the top elevation.
- `theme.html` — the theme's parameters rendered as a reference sheet.
- `templates/landing/` — a starter page consuming the system the intended way (`index.html`, its `ds-base.js` loader, and the vendored `image-slot.js` its photograph mounts).
- `assets/photo.jpg` — the reference photograph the imagery page treats.
