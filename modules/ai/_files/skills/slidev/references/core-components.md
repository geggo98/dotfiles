---
name: components
description: Ready-to-use components in Slidev
---

# Built-in Components

Ready-to-use components in Slidev.

## Navigation

### Link

Navigate to slide:
```md
<Link to="5">Go to slide 5</Link>
<Link to="intro">Go to intro</Link>  <!-- with routeAlias -->
```

### SlideCurrentNo / SlidesTotal

```md
Slide <SlideCurrentNo /> of <SlidesTotal />
```

### Toc (Table of Contents)

```md
<Toc />
<Toc maxDepth="2" />
<Toc columns="2" />
```

Props:
- `columns` - Number of columns
- `maxDepth` / `minDepth` - Heading depth filter
- `mode` - 'all' | 'onlyCurrentTree' | 'onlySiblings'

### TitleRenderer

Render slide title:
```md
<TitleRenderer no="3" />
```

## Animations

### VClick / VClicks

```md
<VClick>Shows on click</VClick>

<VClicks>

- Item 1
- Item 2

</VClicks>
```

### VAfter

```md
<VClick>First</VClick>
<VAfter>Shows with first</VAfter>
```

### VSwitch

```md
<VSwitch>
  <template #1>State 1</template>
  <template #2>State 2</template>
</VSwitch>
```

## Drawing

### Arrow

```md
<Arrow x1="10" y1="10" x2="100" y2="100" />
<Arrow x1="10" y1="10" x2="100" y2="100" two-way />
```

Props: `x1`, `y1`, `x2`, `y2`, `width`, `color`, `two-way`

### VDragArrow

Draggable arrow:
```md
<VDragArrow />
```

## Layout

### Transform

Scale elements:
```md
<Transform :scale="0.5">
  <LargeContent />
</Transform>
```

Props: `scale`, `origin`

### AutoFitText

Auto-sizing text:
```md
<AutoFitText :max="200" :min="50" modelValue="Hello" />
```

## Media

### SlidevVideo

```md
<SlidevVideo v-click autoplay controls>
  <source src="/video.mp4" type="video/mp4" />
</SlidevVideo>
```

Props: `controls`, `autoplay`, `autoreset`, `poster`, `timestamp`

### Youtube

```md
<Youtube id="dQw4w9WgXcQ" />
<Youtube id="dQw4w9WgXcQ" width="600" height="400" />
```

### Tweet

```md
<Tweet id="1423789844234231808" />
<Tweet id="1423789844234231808" :scale="0.8" />
```

## Conditional

### LightOrDark

```md
<LightOrDark>
  <template #dark>Dark mode content</template>
  <template #light>Light mode content</template>
</LightOrDark>
```

### RenderWhen

```md
<RenderWhen context="presenter">
  Only in presenter mode
</RenderWhen>
```

Context values:
- `main` - Main presentation view
- `visible` - Visible slides
- `print` - Print/export mode
- `slide` - Normal slide view
- `overview` - Overview mode
- `presenter` - Presenter mode
- `previewNext` - Next slide preview

## Branding

### PoweredBySlidev

```md
<PoweredBySlidev />
```

## Draggable

### VDrag

```md
<VDrag pos="myElement">
  Draggable content
</VDrag>
```

See [draggable](draggable.md) for details.

## Component Auto-Import

Components from these sources are auto-imported:
1. Built-in components
2. Theme components
3. Addon components
4. `./components/` directory

No import statements needed.

### Logic Modules Under `components/` Can Hide a Component

Slidev registers every `.vue`, `.md`, `.js`, `.ts`, `.jsx` and `.tsx` file under `components/` as a component, recursively, `lib/` and `__tests__/` included. The name is the file name without extension in PascalCase, so `components/ContextHygiene.vue` and `components/lib/contextHygiene.ts` both become `ContextHygiene`. The dev server then warns `component "ContextHygiene"(…/lib/contextHygiene.ts) has naming conflicts with other components, ignored.` and drops one of the two files. It keeps the first path it finds; the plugin documentation does not define that order.

Rule: give a logic module under `components/` a name that no component has, for example with a `Logic`, `Math` or `Data` suffix, or move it out of `components/`. Renaming keeps the file where it is; moving it out removes it from the scan. The clash ignores case, `-` and `_`, so `context-hygiene.ts` also clashes. Test files such as `contextHygiene.test.ts` do not, because the name keeps `.test`. Origin: measured on 23.11.2026 with Slidev 52.14.1 (`createComponentsPlugin` in `@slidev/cli` uses unplugin-vue-components). Limit: the warning appears only after a browser loads a slide, and a running server does not rescan new files; restart it to check.

A test that walks each `components/` directory catches the clash before startup:

```ts
// walk(dir) returns all file paths below dir, recursively
const EXT = new Set([".vue", ".md", ".js", ".ts", ".jsx", ".tsx"]);
const key = (f: string) =>
  basename(f, extname(f)).replace(/[^A-Za-z0-9]/g, "").toLowerCase();
const byKey = new Map<string, string[]>();
for (const f of walk(componentsDir).filter((f) => EXT.has(extname(f))))
  byKey.set(key(f), [...(byKey.get(key(f)) ?? []), f]);
expect([...byKey.values()].filter((g) => g.length > 1)).toEqual([]);
```
