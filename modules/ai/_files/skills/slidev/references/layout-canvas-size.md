---
name: canvas-size
description: Configure slide canvas dimensions and aspect ratio
---

# Slide Canvas Size

Set the canvas dimensions for all slides.

## Configuration

```md
---
aspectRatio: 16/9
canvasWidth: 980
---
```

- `aspectRatio`: Ratio of width to height (default: `16/9`)
- `canvasWidth`: Canvas width in pixels (default: `980`)

## Scaling & overflow (important)

The canvas is a **logical** drawing surface: `canvasWidth × canvasWidth/aspectRatio`
= **980 × 552** by default. Slidev scales it via a CSS `transform` to fill the
viewport. Consequences:

- All your `px` values are **logical** px on the 980×552 canvas. After the title and
  paddings, a default slide leaves only **~400 logical px** of body height.
- Content past the canvas boundary is **clipped silently** in present mode — no
  scrollbar, no warning. A slide can look fine while editing and lose its bottom on
  stage.
- In a test browser, `getBoundingClientRect()` returns **real** (post-scale) px while
  `getComputedStyle().height` is **logical**. At a 1280×720 viewport the scale factor
  is ≈ **1.30**.

Always overflow-check content-heavy slides — see
[testing-overflow](testing-overflow.md).

## Related Features

- Scale individual slides: use `zoom` frontmatter option
- Scale elements: use `<Transform>` component
