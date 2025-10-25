# Nutshell Brand Assets

This folder contains the official Nutshell visual identity.

🚨 IMPORTANT:
- Do NOT edit, recolor, restyle, or re-type the logo.
- Do NOT change spacing between orb / text / tagline.
- Do NOT add drop-shadows / outlines on top of what’s already there.
- The glow, gradients, and tagline are part of the brand and must stay.

---

## 1. Brand Name

**Product name:** `Nutshell`  
**Tagline:** `INSTANT NEWS`

Tagline can be omitted in very tight spaces (favicon, app icon), but never rewritten.

Examples:
- ✅ `Nutshell`
- ✅ `Nutshell — INSTANT NEWS`
- ❌ `Nutshell News`
- ❌ `Nutshell: Fast Bollywood Updates`
- ❌ `Nutshell App`

---

## 2. Logo Variants

There are only TWO official themes:

### A. Dark Theme Logo  
File examples:
- `nutshell-full-dark-1600x900.png`
- `nutshell-full-dark-1200.png`
- `nutshell-lockup-dark-transparent.png`

Usage:
- Dark backgrounds (navy, black, gradients, hero sections)
- App splash on dark mode
- Social headers with dark background
- In-app “About” screen for dark mode

Appearance:
- Deep navy / near-black background
- Orb with blue/aqua/purple glow
- “Nutshell” in white
- “INSTANT NEWS” in cyan with glow bar

### B. Light Theme Logo  
File examples:
- `nutshell-full-light-1600x900.png`
- `nutshell-full-light-1200.png`
- `nutshell-lockup-light-transparent.png`

Usage:
- White / light gray backgrounds
- Press kits, decks, investor docs
- Light mode splash / marketing site hero

Appearance:
- White background
- Orb same blue blend
- “Nutshell” in deep navy
- “INSTANT NEWS” in deep navy with a subtle aqua glow underline

❗ These are the ONLY allowed looks. No “all black” / “all white” flat logo. The glow is part of the identity.

---

## 3. Asset Types

We ship two structures:

### 3.1 Orb-only (icon)
This is JUST the glossy circular orb with the “N”.  
No “Nutshell”. No “INSTANT NEWS”. No glow bar text.

**Use this for:**
- App icon (iOS / Android)
- Notification icon
- Social profile avatar
- Favicon base

**Exports you should have:**

#### Dark background versions
- `nutshell-orb-1024-dark.png`
- `nutshell-orb-512-dark.png`
- `nutshell-orb-256-dark.png`
- `nutshell-orb-128-dark.png`
- `nutshell-orb-32-dark.png`

Background: pure black (#000000) / deep navy, same as approved dark logo.  
The orb stays exactly as designed. Do not crop glow.

#### Light background versions
- `nutshell-orb-1024-light.png`
- `nutshell-orb-512-light.png`
- `nutshell-orb-256-light.png`
- `nutshell-orb-128-light.png`
- `nutshell-orb-32-light.png`

Background: pure white (#FFFFFF).  
Same orb, unchanged.

**Rules:**
- Always export as a perfect square.
- Keep the orb perfectly centered.
- Keep the full glow ring visible.
- Do NOT manually round the corners (iOS / Android will round on device).

---

### 3.2 Full lockup (logo with text)
This is the full brand:  
Orb + “Nutshell” + “INSTANT NEWS” + glow underline.

**Use this for:**
- App splash screen
- Marketing hero / landing page header
- Social banner
- Press / pitch decks
- Store listing graphics

**Exports you should have:**

#### Landscape hero
- `nutshell-full-dark-1600x900.png`
- `nutshell-full-light-1600x900.png`

Canvas: 1600 x 900  
Layout: orb above “Nutshell”, tagline below, glow bar under tagline.  
Centered vertically with breathing room.

#### Square social / press
- `nutshell-full-dark-1200.png`
- `nutshell-full-light-1200.png`

Canvas: 1200 x 1200  
Same layout, just centered in a square.  
This is great for IG posts, LinkedIn posts, thumbnails, PR kits.

---

### 3.3 Transparent lockup (for overlaying on anything)
Same as full lockup, but with NO background fill.

**Use this for:**
- Slides / keynote decks
- App Store screenshots
- Watermarking

**Exports:**
- `nutshell-lockup-dark-transparent.png`
- `nutshell-lockup-light-transparent.png`

Specs:
- ~2000 px wide (keeps it crisp in decks and 4K screenshots)
- Transparent background (alpha)
- KEEP:
  - Glow around the orb
  - Glow underline under “INSTANT NEWS”
- Do NOT flatten out or remove glow

Also export SVG versions of these two for perfect scaling in web/app UI:
- `nutshell-lockup-dark-transparent.svg`
- `nutshell-lockup-light-transparent.svg`

SVG must match pixel version exactly (no color changes, no font swaps).

---

## 4. Web / App integration

### Favicons
Use the orb-only light version for browser/favicon:

- `favicon-32.png` → alias of `nutshell-orb-32-light.png`
- `favicon-16.png` → downscaled version
- `favicon.ico`   → generated ICO from the 32px orb

Put these in your site `<head>`:

```html
<link rel="icon" type="image/png" sizes="32x32" href="/favicon-32.png">
<link rel="icon" type="image/png" sizes="16x16" href="/favicon-16.png">
<link rel="shortcut icon" href="/favicon.ico">
