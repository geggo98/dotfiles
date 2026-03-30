---
name: dark-light-mode
description: Supporting dark and light mode in Vue components, CSS, and frontmatter
---

# Dark / Light Mode in Slidev

Slidev supports dark/light mode switching. Here are all ways to react to or control the mode in custom Vue components and slides.

## JavaScript: `useDarkMode()` Composable

```vue
<script setup>
import { useDarkMode } from '@slidev/client'

const { isDark, toggleDark } = useDarkMode()
</script>

<template>
  <div>
    <p>Current: {{ isDark ? 'Dark' : 'Light' }}</p>
    <button @click="toggleDark()">Toggle</button>
  </div>
</template>
```

Use this when you need logic-based differences between modes.

## Built-in `<LightOrDark>` Component

```vue
<LightOrDark>
  <template #light>Light mode content</template>
  <template #dark>Dark mode content</template>
</LightOrDark>
```

Renders only the matching slot based on current mode. Good for swapping images or entirely different markup.

## CSS Approaches

### 1. CSS Classes on `<html>`

Slidev sets `dark` or `light` class on the `<html>` element:

```css
html.dark .my-component {
  background: #1a1a1a;
  color: white;
}

html:not(.dark) .my-component {
  background: white;
  color: black;
}
```

### 2. UnoCSS / Tailwind `dark:` Prefix

```html
<div class="bg-white dark:bg-[#121212] text-black dark:text-white">
  Adapts automatically
</div>
```

Simplest approach for purely visual adjustments.

### 3. CSS Variables

Slidev defines built-in variables that change with the mode (e.g. `--slidev-code-background`). Define custom ones:

```css
:root {
  --my-bg: white;
}
html.dark {
  --my-bg: #1a1a1a;
}
.my-component {
  background: var(--my-bg);
}
```

## Frontmatter Control

Force or allow mode switching per deck or per slide:

```yaml
---
colorSchema: dark    # always dark
colorSchema: light   # always light
colorSchema: all     # toggle allowed (default-like)
---
```

## Quick Decision Guide

| Need | Approach |
|------|----------|
| Visual-only styling | `dark:` UnoCSS/Tailwind classes |
| CSS with shared selectors | `html.dark` / `html:not(.dark)` classes |
| Theming with variables | CSS custom properties on `:root` / `html.dark` |
| Swap entire content blocks | `<LightOrDark>` component |
| Conditional logic in JS | `useDarkMode()` composable |
| Lock mode for entire deck | `colorSchema` in headmatter |
