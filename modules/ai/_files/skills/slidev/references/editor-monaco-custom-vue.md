---
name: monaco-custom-vue
description: Use Monaco editor inside custom Vue components (auto-registered, lz-string, direct API, global config)
---

# Monaco in Custom Vue Components

Use the Monaco editor inside your own Vue components under `components/`.

**Prerequisite:** `monaco: true` must be set in the Slidev frontmatter or `config.ts`.

## 1. `<Monaco>` Component (Simplest)

Slidev uses `unplugin-vue-components`, so `<Monaco>` is auto-registered — no import needed.

```vue
<!-- components/MyCodeDemo.vue -->
<script setup>
import { compressToBase64 } from 'lz-string'

const code = compressToBase64(`console.log("Hello!")`)
</script>

<template>
  <Monaco
    :codeLz="code"
    lang="typescript"
    :height="200"
    :lineNumbers="'on'"
    :readonly="false"
  />
</template>
```

**Important:** Code must be compressed with `lz-string` (`compressToBase64`) — the component expects this internally.

### Props

| Prop | Type | Description |
|---|---|---|
| `codeLz` | `string` | Code, Base64-compressed via lz-string |
| `diffLz` | `string` | Diff code for diff editor |
| `lang` | `string` | Language (`ts`, `js`, `vue`, `css`, ...) |
| `readonly` | `boolean` | Read-only mode |
| `lineNumbers` | `'on' \| 'off'` | Show line numbers |
| `height` | `number \| string` | Height (`'auto'`, px, %) |
| `editorOptions` | `object` | Full Monaco `IEditorOptions` |
| `runnable` | `boolean` | Make code runnable |
| `ata` | `boolean` | Auto Type Acquisition |

## 2. Monaco API Directly (Full Control)

For maximum flexibility, use the Monaco instance directly:

```vue
<!-- components/CustomEditor.vue -->
<script setup>
import { ref, onMounted } from 'vue'

const container = ref()

onMounted(async () => {
  const { default: setup } = await import('@slidev/client/setup/monaco')
  const { monaco } = await setup()

  const model = monaco.editor.createModel('const x = 42', 'typescript')
  monaco.editor.create(container.value, {
    model,
    minimap: { enabled: false },
    fontSize: 14,
  })
})
</script>

<template>
  <div ref="container" style="height: 300px" />
</template>
```

## 3. Full Example: Read-Only Editor with Custom Themes and Dark Mode

A reusable component that imports `monaco-editor` directly, defines custom light/dark themes, and reacts to Slidev's dark mode via `useDarkMode()`:

```vue
<!-- components/CodeBlock.vue -->
<script setup>
import { ref, onMounted, onBeforeUnmount, watchEffect } from 'vue'
import { useDarkMode } from '@slidev/client'

const props = defineProps({
  code: { type: String, required: true },
  language: { type: String, default: 'yaml' },
  height: { type: String, default: '180px' },
})

const { isDark } = useDarkMode()
const container = ref(null)
let editor = null
let monaco = null

onMounted(async () => {
  const monacoModule = await import('monaco-editor')
  monaco = monacoModule
  if (!container.value) return

  monaco.editor.defineTheme('mb-dark', {
    base: 'vs-dark',
    inherit: true,
    rules: [
      { token: 'comment', foreground: '6a737d', fontStyle: 'italic' },
      { token: 'constant', foreground: '79b8ff' },
      { token: 'keyword', foreground: 'f97583' },
      { token: 'string', foreground: '9ecbff' },
      { token: 'tag', foreground: '85e89d' },
      { token: 'type', foreground: '79b8ff' },
      { token: 'number', foreground: '79b8ff' },
    ],
    colors: {
      'editor.background': '#24292e',
      'editor.foreground': '#e1e4e8',
      'editorLineNumber.foreground': '#444d56',
      'editor.selectionBackground': '#3392FF44',
      'editor.lineHighlightBackground': '#2b3036',
      'editorGutter.background': '#24292e',
    },
  })

  monaco.editor.defineTheme('mb-light', {
    base: 'vs',
    inherit: true,
    rules: [
      { token: 'comment', foreground: '6a737d', fontStyle: 'italic' },
      { token: 'constant', foreground: '005cc5' },
      { token: 'keyword', foreground: 'd73a49' },
      { token: 'string', foreground: '032f62' },
      { token: 'tag', foreground: '22863a' },
      { token: 'type', foreground: '005cc5' },
      { token: 'number', foreground: '005cc5' },
    ],
    colors: {
      'editor.background': '#ffffff',
      'editor.foreground': '#24292e',
      'editorLineNumber.foreground': '#1b1f234d',
      'editor.selectionBackground': '#0366d625',
      'editor.lineHighlightBackground': '#f6f8fa',
      'editorGutter.background': '#ffffff',
    },
  })

  editor = monaco.editor.create(container.value, {
    value: props.code,
    language: props.language,
    theme: isDark.value ? 'mb-dark' : 'mb-light',
    readOnly: true,
    automaticLayout: true,
    fontSize: 12,
    lineHeight: 22,
    fontFamily: 'var(--font-mono)',
    lineNumbers: 'on',
    lineNumbersMinChars: 3,
    minimap: { enabled: false },
    scrollBeyondLastLine: false,
    glyphMargin: false,
    folding: false,
    renderLineHighlight: 'none',
    codeLens: false,
    scrollbar: { vertical: 'auto', horizontal: 'auto' },
    padding: { top: 6, bottom: 6 },
    overviewRulerLanes: 0,
    overviewRulerBorder: false,
    hideCursorInOverviewRuler: true,
    contextmenu: false,
    wordWrap: 'off',
    lineDecorationsWidth: 0,
    bracketPairColorization: { enabled: false },
  })

  watchEffect(() => {
    monaco.editor.setTheme(isDark.value ? 'mb-dark' : 'mb-light')
  })
})

onBeforeUnmount(() => {
  editor?.dispose()
})
</script>

<template>
  <div class="monaco-block" :style="{ height }">
    <div ref="container" class="monaco-container" />
  </div>
</template>

<style scoped>
.monaco-block {
  border-radius: var(--sk-radm);
  overflow: hidden;
  border: 0.5px solid var(--color-border-tertiary);
  margin: 8px 0;
}
.monaco-container {
  width: 100%;
  height: 100%;
}
</style>
```

Key patterns demonstrated:
- **Direct `monaco-editor` import** instead of Slidev's setup wrapper
- **Custom themes** with `defineTheme()` for both light and dark mode
- **Dark mode reactivity** via `useDarkMode()` + `watchEffect` to switch themes live
- **Cleanup** with `editor.dispose()` in `onBeforeUnmount`
- **Presentation-friendly defaults**: no minimap, no context menu, no folding, read-only

## 4. Global Monaco Configuration

Configure editor options for all Monaco instances via `setup/monaco.ts`:

```ts
// setup/monaco.ts
import { defineMonacoSetup } from '@slidev/types'

export default defineMonacoSetup(async (monaco) => {
  return {
    editorOptions: {
      wordWrap: 'on',
      fontSize: 14,
    }
  }
})
```
