# Testing Slidev Presentations with Playwright

End-to-end testing of Slidev presentations using Playwright. Covers setup, DOM structure, navigation, Vue component testing, click animations, computed CSS assertions, and common patterns.

## Architecture

Slidev serves presentations as a Vue SPA on a Vite dev server. Every slide is a Vue component rendered in the browser. Custom Vue components placed in `components/` are auto-discovered via `unplugin-vue-components`. This means everything is testable through standard browser automation — no special framework adapter is needed.

## Setup

### Install Dependencies

```bash
bun add -D @playwright/test
bunx playwright install chromium  # or: --with-deps chromium
```

### Playwright Config with Dynamic Port

Slidev already depends on `get-port-please`. Use it to avoid port conflicts:

```ts
// playwright.config.ts
import { defineConfig } from '@playwright/test'
import { getPort } from 'get-port-please'

const port = await getPort({ port: 3030, portRange: [3030, 4000] })

export default defineConfig({
  testDir: './tests/e2e',
  webServer: {
    command: `bunx slidev --port ${port}`,
    port,
    reuseExistingServer: true,
    timeout: 30_000,
  },
  use: {
    baseURL: `http://localhost:${port}`,
  },
  projects: [
    { name: 'chromium', use: { browserName: 'chromium' } },
  ],
})
```

### Alternative: Fixed Port

```ts
// playwright.config.ts
import { defineConfig } from '@playwright/test'

export default defineConfig({
  webServer: {
    command: 'bunx slidev --port 3030',
    port: 3030,
    reuseExistingServer: true,
  },
  use: {
    baseURL: 'http://localhost:3030',
  },
})
```

## Slidev DOM Structure

Understanding the DOM hierarchy is critical for writing reliable selectors:

```
#page-root
  #slide-container
    #slide-content
      #slideshow
        .slidev-page-{N}          ← each slide, where N = slide number
          div
            p, h1, h2, ...       ← markdown-rendered content
            .slidev-code          ← code blocks
            .slidev-vclick-target ← elements controlled by v-click
```

### Key Selectors

| Element | Selector |
|---------|----------|
| Slide N | `.slidev-page-{N}` |
| Slide content area | `#slide-content` |
| Code block | `.slidev-code` |
| v-click visible | `.slidev-vclick-target:not(.slidev-vclick-hidden)` |
| v-click hidden | `.slidev-vclick-target.slidev-vclick-hidden` |
| Column layout right | `.col-right` |
| Global footer | Text-based: `page.getByText('Footer Text')` |
| Presenter notes resizer | `.note .notes-resizer` |
| Grid container | `.grid-container` |

## Navigation

### Keyboard Navigation

```ts
// Next slide / next click step
await page.keyboard.press('ArrowRight')

// Previous slide / previous click step
await page.keyboard.press('ArrowLeft')

// Next slide (skip click steps)
await page.keyboard.press('ArrowDown')

// Previous slide (skip click steps)
await page.keyboard.press('ArrowUp')
```

### Go-to-Page Navigation

Slidev supports pressing `g` to open a goto dialog:

```ts
async function goToSlide(page: Page, slideNumber: number) {
  await page.keyboard.press('g')
  await page.locator('#slidev-goto-input').fill(String(slideNumber))
  await page.keyboard.press('Enter')
  // Wait for navigation to complete
  await page.waitForURL(new RegExp(`/${slideNumber}(\\?|$)`))
}
```

### URL Structure

| View | URL |
|------|-----|
| Slide N | `/{N}` |
| Slide N with clicks | `/{N}?clicks={M}` |
| Presenter mode | `/presenter` |
| Overview | `/overview` |
| Entry page | `/entry` |

### Helper: Advance Multiple Clicks

```ts
async function advanceClicks(page: Page, n: number) {
  for (let i = 0; i < n; i++) {
    await page.keyboard.press('ArrowRight')
    // Small delay for animation to settle
    await page.waitForTimeout(200)
  }
}
```

## Testing Patterns

### Basic Slide Content

```ts
import { test, expect } from '@playwright/test'

test('slide 1 renders title', async ({ page }) => {
  await page.goto('/')
  await expect(page.locator('.slidev-page-1')).toBeVisible()
  await expect(page.locator('.slidev-page-1 h1')).toHaveText('My Title')
})
```

### Custom Vue Components

Vue components in `components/` are rendered as standard DOM elements. Test them by their rendered output:

```ts
test('custom component renders correctly', async ({ page }) => {
  await page.goto('/3')  // slide that uses <MyChart />
  await expect(page.locator('.slidev-page-3 .my-chart')).toBeVisible()
  await expect(page.locator('.slidev-page-3 .my-chart .bar')).toHaveCount(5)
})
```

For components with interactivity:

```ts
test('interactive component responds to clicks', async ({ page }) => {
  await page.goto('/4')
  const counter = page.locator('.slidev-page-4 .counter')
  await expect(counter).toHaveText('0')
  await counter.locator('button').click()
  await expect(counter).toHaveText('1')
})
```

### v-click Animations

v-click elements start hidden and reveal progressively with `ArrowRight`:

```ts
test('v-click reveals items step by step', async ({ page }) => {
  await page.goto('/9')

  // Initially hidden
  const visible = page.locator(
    '.slidev-page-9 .slidev-vclick-target:not(.slidev-vclick-hidden)'
  )

  // Step 1: press right to reveal first v-click group
  await page.keyboard.press('ArrowRight')
  await expect(visible).toHaveText('CD')

  // Step 2-3: reveal more
  await page.keyboard.press('ArrowRight')
  await page.keyboard.press('ArrowRight')
  await expect(visible).toHaveText('ABCD')

  // Step 4: v-click.hide removes an element
  await page.keyboard.press('ArrowRight')
  await expect(visible).toHaveText('ABC')
})
```

### Nested v-clicks (Deep Lists)

```ts
test('deeply nested v-clicks', async ({ page }) => {
  await page.goto('/11')

  const deepVisible = page.locator(
    '.slidev-page-11 .cy-depth ' +
    '.slidev-vclick-target:not(.slidev-vclick-hidden) ' +
    '.slidev-vclick-target:not(.slidev-vclick-hidden) ' +
    '.slidev-vclick-target:not(.slidev-vclick-hidden)'
  )

  await advanceClicks(page, 3)
  await expect(deepVisible).toHaveText('C')

  await advanceClicks(page, 3)
  await expect(deepVisible).toHaveText('CD')
})
```

### Layout Slots (e.g., Two Columns)

```ts
test('two-cols layout has right column', async ({ page }) => {
  await page.goto('/8')
  await expect(page.locator('.col-right')).toContainText('Right')
})
```

### Code Blocks

```ts
test('code block renders correctly', async ({ page }) => {
  await page.goto('/5')
  await expect(page.locator('.slidev-page-5 .slidev-code'))
    .toHaveText('<div>{{$slidev.nav.currentPage}}</div>')
})
```

### Dynamic Content ($slidev Context)

```ts
test('$slidev.nav.currentPage is correct', async ({ page }) => {
  await page.goto('/5')
  await expect(page.locator('.slidev-page-5 > div > p'))
    .toHaveText('Current Page: 5')
})
```

### Global Elements (Footer, Layers)

```ts
test('global footer visible on slide 1', async ({ page }) => {
  await page.goto('/1')
  await expect(page.getByText('Global Footer')).toBeVisible()
})

test('global footer hidden on slide 2', async ({ page }) => {
  await page.goto('/2')
  await expect(page.getByText('Global Footer')).not.toBeVisible()
})
```

## Computed CSS Assertions

### Using `toHaveCSS` (Recommended)

`toHaveCSS` checks the **computed** (final rendered) value and includes auto-retry:

```ts
test('slide 2 paragraph has green border', async ({ page }) => {
  await page.goto('/2')
  await expect(page.locator('.slidev-page-2 > div > p'))
    .toHaveCSS('border-color', 'rgb(0, 128, 0)')
})
```

### Negative CSS Assertions

```ts
await expect(page.locator('.slidev-page-2 > div > p'))
  .not.toHaveCSS('color', 'rgb(128, 0, 0)')
```

### Using `evaluate` + `getComputedStyle` (For Complex Checks)

When you need the raw value for arithmetic or multiple properties at once:

```ts
test('heading font size is at least 24px', async ({ page }) => {
  await page.goto('/1')
  const fontSize = await page.locator('.slidev-page-1 h1').evaluate(el =>
    parseFloat(getComputedStyle(el).fontSize)
  )
  expect(fontSize).toBeGreaterThanOrEqual(24)
})
```

### Reusable CSS Helper

```ts
async function getStyle(locator: Locator, prop: string): Promise<string> {
  return locator.evaluate(
    (el, p) => getComputedStyle(el).getPropertyValue(p), prop
  )
}

// Usage
const bg = await getStyle(page.locator('.slide'), 'background-color')
expect(bg).toBe('rgb(255, 255, 255)')
```

### CSS Custom Properties (Variables)

Slidev uses CSS variables for dynamic sizing. Check them via the `style` attribute or `getComputedStyle`:

```ts
test('presenter grid uses CSS variables', async ({ page }) => {
  await page.goto('/presenter')
  const style = await page.locator('.grid-container').getAttribute('style')
  expect(style).toContain('--slidev-presenter-notes-width')
  expect(style).toContain('--slidev-presenter-notes-row-size')
})
```

## Testing Presenter Mode

```ts
test('presenter mode loads', async ({ page }) => {
  await page.goto('/presenter')
  await expect(page.locator('.note')).toBeVisible()
})

test('presenter resizer handles exist in layout 1', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('slidev-presenter-layout', '1')
  })
  await page.goto('/presenter')

  await expect(page.locator('.note .notes-resizer')).toBeVisible()
  await expect(page.locator('.note .notes-row-resizer')).toBeVisible()
})
```

## Testing Viewport / Responsive Behavior

```ts
test('presenter layout adapts to wide viewport', async ({ page }) => {
  await page.setViewportSize({ width: 1400, height: 900 })
  await page.addInitScript(() => {
    localStorage.setItem('slidev-presenter-layout', '1')
  })
  await page.goto('/presenter')
  await expect(page.locator('.notes-vertical-resizer')).toBeVisible()
  await expect(page.locator('.note .notes-resizer')).not.toBeVisible()
})
```

## Smoke Test: Walk All Slides

Verify that every slide renders without errors:

```ts
test('all slides render without errors', async ({ page }) => {
  const errors: string[] = []
  page.on('pageerror', err => errors.push(err.message))

  await page.goto('/')

  while (true) {
    const urlBefore = page.url()
    await page.keyboard.press('ArrowDown')  // next slide (skip clicks)
    await page.waitForTimeout(500)
    const urlAfter = page.url()
    if (urlBefore === urlAfter) break  // reached last slide
  }

  expect(errors).toEqual([])
})

test('presenter mode renders without errors', async ({ page }) => {
  const errors: string[] = []
  page.on('pageerror', err => errors.push(err.message))
  await page.goto('/presenter')
  await page.waitForTimeout(2000)
  expect(errors).toEqual([])
})

test('overview page renders without errors', async ({ page }) => {
  const errors: string[] = []
  page.on('pageerror', err => errors.push(err.message))
  await page.goto('/overview')
  await page.waitForTimeout(2000)
  expect(errors).toEqual([])
})
```

## Overview Mode

```ts
test('overview navigation with keyboard', async ({ page }) => {
  await page.goto('/2')

  // Open overview
  await page.keyboard.press('o')

  // Navigate in grid
  await page.keyboard.press('ArrowRight')
  await page.keyboard.press('ArrowRight')

  // Select slide
  await page.keyboard.press('Enter')
  await page.waitForURL(/\/4$/)
})
```

## Tips

- **Wait for slides to load**: After `goto()`, wait for `.slidev-page-{N}` to be visible before asserting.
- **Animation timing**: Use `await page.waitForTimeout(200)` between rapid click steps, or use `toHaveCSS` / `toBeVisible` which auto-retry.
- **Click steps vs slides**: `ArrowRight` advances one click step. If there are no more click steps, it moves to the next slide. `ArrowDown` always skips to the next slide.
- **Computed colors**: Browsers return computed colors as `rgb(R, G, B)` — not hex or named colors. Always assert with `rgb()` format.
- **Custom component selectors**: Use CSS class names from your Vue component templates. Slidev does not add special wrappers around custom components.
- **Parallel tests**: Each Playwright test gets its own browser context, so tests can run in parallel without interfering with each other's slide state.
- **Screenshots for visual regression**: Playwright supports `await expect(page).toHaveScreenshot()` for pixel-level comparison of rendered slides.

## Visual Regression Testing

Capture and compare slide screenshots:

```ts
test('slide 1 matches snapshot', async ({ page }) => {
  await page.goto('/1')
  await expect(page.locator('.slidev-page-1')).toBeVisible()
  await expect(page).toHaveScreenshot('slide-1.png')
})

test('slide with v-clicks after reveal', async ({ page }) => {
  await page.goto('/9')
  await page.keyboard.press('ArrowRight')
  await page.waitForTimeout(300)
  await expect(page).toHaveScreenshot('slide-9-click-1.png')
})
```

Update snapshots: `bunx playwright test --update-snapshots`
