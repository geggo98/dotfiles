---
name: sections-toc
description: Chapter/section dividers, the <Toc> component, and the hideInToc pattern
---

# Sections, Table of Contents & `hideInToc`

How to give a longer deck chapter dividers and an agenda slide that lists **only**
those chapters.

## Section divider slides

A chapter divider is just a slide with `layout: section` and a level‑1 heading
(plus an optional subtitle line):

```md
---
layout: section
---

# 1. What OpenRewrite is

Format-preserving and type-aware — the LST foundation
```

## The `<Toc>` agenda slide

```md
---
hideInToc: true
---

# Agenda

<Toc mode="all" minDepth="1" maxDepth="1" columns="2" listClass="!list-none !pl-0" />
```

`<Toc>` props (see also [core-components](core-components.md)):

- `mode` — `all` | `onlyCurrentTree` | `onlySiblings`
- `minDepth` / `maxDepth` — heading‑depth filter
- `columns` — number of columns
- `listClass` — UnoCSS/Tailwind classes for the list (e.g. `!list-none !pl-0` to drop bullets/indent)

## The non‑obvious part: how slides get *into* the TOC

`<Toc>` lists each **slide** by the heading level of its **title**, filtered by
`minDepth`/`maxDepth`. With `minDepth="1" maxDepth="1"` it lists every slide whose
title is an `#` (h1).

The catch: content slides usually *also* use `#` for their titles, so the depth
filter alone does **not** restrict the TOC to chapter dividers — it would list
every content slide too. The real lever is **`hideInToc: true`**, which you put in
the per‑slide frontmatter of **every non‑divider slide**:

- the cover (in the headmatter),
- the TL;DR / agenda slide itself,
- and every content slide.

Only the `layout: section` dividers are left without `hideInToc`, so the TOC ends
up listing exactly the chapters. (`hideInToc` lives in `core-frontmatter`; it also
works in the deck headmatter for the cover.)

```md
---
hideInToc: true        # ← on every content slide
---

# A content slide (h1 title, but kept out of the TOC)
```

A real deck of N slides with 7 chapters therefore has ~N `hideInToc: true` blocks
and 7 un‑hidden `layout: section` slides.

### Alternative: use heading levels instead

If you'd rather not repeat `hideInToc` everywhere, give **chapter dividers** an
`#` (h1) title and **content slides** a `##` (h2) title, then `<Toc minDepth="1"
maxDepth="1">` naturally lists only the dividers. The trade‑off: content‑slide
titles render at the smaller h2 size in the default theme, so most decks prefer
the `#`‑everywhere + `hideInToc` pattern above.

## Quick recipe

1. Cover slide: headmatter has `hideInToc: true`.
2. Agenda slide: `hideInToc: true` + `<Toc minDepth="1" maxDepth="1" .../>`.
3. Each chapter: `---\nlayout: section\n---\n# N. Title`.
4. Every other slide: start its frontmatter with `hideInToc: true`.
