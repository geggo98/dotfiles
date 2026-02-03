#!/usr/bin/env -S deno run --allow-env
// Library functions used by tools/streamdeck_manifest.ts

import Ajv, { type ErrorObject } from "npm:ajv@8.12.0";
import addFormats from "npm:ajv-formats@2.1.1";

import { parse as parseJsonc } from "jsr:@std/jsonc@1";
import { dirname, extname, join, normalize, sep } from "jsr:@std/path@1";
import { deflateSync } from "node:zlib";

export type Level = "error" | "warning";

export type Finding = {
  level: Level;
  code: string;
  message: string;
  /** JSONPath-ish pointer like $.Actions[0].States[0].Image */
  path?: string;
  /** Optional suggested fix */
  hint?: string;
};

export type ValidationMeta = {
  schemaUrl: string;
  schemaFromCache: boolean;
  parsedAsJsonc: boolean;
};

export type ValidationResult = {
  ok: boolean;
  errors: Finding[];
  warnings: Finding[];
  meta: ValidationMeta;
};

export type LoadSchemaResult = {
  schema: unknown;
  fromCache: boolean;
  cachePath: string;
  schemaUrl: string;
  /** Populated when the network fetch failed but cache was used. */
  fetchWarning?: string;
};

export type ParseManifestResult = {
  value: unknown;
  parsedAsJsonc: boolean;
  parseError?: string;
};

export type ValidateOptions = {
  manifestPath: string;
  schemaUrl?: string;
  refreshSchema?: boolean;
  cacheDir?: string;
  checkAssets?: boolean;
  failOnWarn?: boolean;
  fixJsonc?: boolean;
  write?: boolean;
};

export function isPlainObject(
  value: unknown,
): value is Record<string, unknown> {
  if (value === null || typeof value !== "object") return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

export async function fileExists(path: string): Promise<boolean> {
  try {
    const st = await Deno.stat(path);
    return st.isFile;
  } catch {
    return false;
  }
}

export async function ensureDir(path: string): Promise<void> {
  await Deno.mkdir(path, { recursive: true });
}

function encodeUtf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

function decodeUtf8(b: Uint8Array): string {
  return new TextDecoder().decode(b);
}

function isDisallowedPathFragment(p: string): boolean {
  // Stream Deck manifest paths are expected to be relative and forward-slash oriented.
  // The official schema pattern usually blocks traversal, but we enforce it defensively.
  if (p.includes("\\")) return true;
  const n = normalize(p);
  if (n.startsWith("..") || n.includes("../") || n.includes("..\\"))
    return true;
  if (p.startsWith("/")) return true;
  // Windows absolute paths like C:\...
  if (/^[a-zA-Z]:[\\/]/.test(p)) return true;
  return false;
}

function toJsonPath(instancePath: string): string {
  if (!instancePath) return "$";
  // Ajv instancePath is JSON Pointer (leading /)
  const parts = instancePath
    .split("/")
    .filter(Boolean)
    .map((p) => p.replace(/~1/g, "/").replace(/~0/g, "~"));
  let out = "$";
  for (const part of parts) {
    if (/^\d+$/.test(part)) out += `[${part}]`;
    else out += `.${part}`;
  }
  return out;
}

export async function parseManifestText(
  text: string,
): Promise<ParseManifestResult> {
  try {
    return { value: JSON.parse(text), parsedAsJsonc: false };
  } catch {
    // Fall back to JSONC (accepts comments and trailing commas)
    try {
      const v = parseJsonc(text);
      return { value: v, parsedAsJsonc: true };
    } catch (e) {
      return {
        value: undefined,
        parsedAsJsonc: false,
        parseError: e instanceof Error ? e.message : String(e),
      };
    }
  }
}

export async function readAndParseManifestFile(
  manifestPath: string,
): Promise<
  | { parsed: ParseManifestResult; rawText: string }
  | { parsed: ParseManifestResult; rawText: null }
> {
  try {
    const rawText = await Deno.readTextFile(manifestPath);
    const parsed = await parseManifestText(rawText);
    return { parsed, rawText };
  } catch (e) {
    return {
      parsed: {
        value: undefined,
        parsedAsJsonc: false,
        parseError: e instanceof Error ? e.message : String(e),
      },
      rawText: null,
    };
  }
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = encodeUtf8(input);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const arr = new Uint8Array(digest);
  return Array.from(arr)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function loadSchemaWithCache(
  schemaUrl: string,
  cacheDir: string,
  refresh = false,
): Promise<LoadSchemaResult> {
  await ensureDir(cacheDir);
  const key = await sha256Hex(schemaUrl);
  const cachePath = join(cacheDir, `${key}.json`);

  const cached = !refresh && (await fileExists(cachePath));
  if (cached) {
    const schemaText = await Deno.readTextFile(cachePath);
    return {
      schema: JSON.parse(schemaText),
      fromCache: true,
      cachePath,
      schemaUrl,
    };
  }

  let fetchWarning: string | undefined;
  try {
    const res = await fetch(schemaUrl);
    if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText}`);
    const schemaText = await res.text();
    // Write cache first so a later JSON.parse error still leaves raw schema for debugging.
    await Deno.writeTextFile(cachePath, schemaText);
    return {
      schema: JSON.parse(schemaText),
      fromCache: false,
      cachePath,
      schemaUrl,
    };
  } catch (e) {
    // Fallback to cache if available.
    if (await fileExists(cachePath)) {
      fetchWarning = `Schema fetch failed; using cached schema. (${e instanceof Error ? e.message : String(e)})`;
      const schemaText = await Deno.readTextFile(cachePath);
      return {
        schema: JSON.parse(schemaText),
        fromCache: true,
        cachePath,
        schemaUrl,
        fetchWarning,
      };
    }
    throw e;
  }
}

export async function validateAgainstSchema(
  manifest: unknown,
  schemaUrl: string,
  cacheDir: string,
  refreshSchema = false,
): Promise<{
  errors: Finding[];
  warnings: Finding[];
  meta: { schemaFromCache: boolean };
}> {
  const loaded = await loadSchemaWithCache(schemaUrl, cacheDir, refreshSchema);
  const warnings: Finding[] = [];
  if (loaded.fetchWarning) {
    warnings.push({
      level: "warning",
      code: "schema.fetch_fallback",
      message: loaded.fetchWarning,
    });
  }

  const ajv = new Ajv({
    allErrors: true,
    strict: false,
    allowUnionTypes: true,
  });
  addFormats(ajv);

  const validate = ajv.compile(loaded.schema as any);
  const ok = validate(manifest);
  if (ok) {
    return {
      errors: [],
      warnings,
      meta: { schemaFromCache: loaded.fromCache },
    };
  }

  const errors: Finding[] = [];
  for (const err of validate.errors ?? []) {
    errors.push(ajvErrorToFinding(err));
  }
  return { errors, warnings, meta: { schemaFromCache: loaded.fromCache } };
}

function ajvErrorToFinding(err: ErrorObject): Finding {
  const basePath = toJsonPath(err.instancePath);
  const code = `schema.${err.keyword}`;

  // Improve a few common messages.
  if (
    err.keyword === "required" &&
    typeof (err.params as any)?.missingProperty === "string"
  ) {
    const missing = (err.params as any).missingProperty;
    return {
      level: "error",
      code,
      message: `Missing required property: ${missing}`,
      path: basePath,
    };
  }

  if (err.keyword === "type" && typeof (err.params as any)?.type === "string") {
    return {
      level: "error",
      code,
      message: `Wrong type: expected ${(err.params as any).type}`,
      path: basePath,
    };
  }

  return {
    level: "error",
    code,
    message: err.message ? err.message : "Schema validation error",
    path: basePath,
  };
}

type ExpectedDims = { base: [number, number]; twoX?: [number, number] };

function dimsToString(d: [number, number]): string {
  return `${d[0]}×${d[1]}`;
}

function looksLikeExtensionlessRef(p: string): boolean {
  // Treat a terminal ".ext" as an extension; dots in folders are rare.
  return extname(p) === "";
}

function joinManifestPath(rootDir: string, rel: string): string {
  // Manifest paths use forward slashes regardless of OS. Deno is fine with them.
  return join(rootDir, rel);
}

async function readFileBytes(path: string): Promise<Uint8Array> {
  return await Deno.readFile(path);
}

function pngDimensions(
  bytes: Uint8Array,
): { width: number; height: number } | null {
  // PNG signature + IHDR
  if (bytes.length < 24) return null;
  const sig = [137, 80, 78, 71, 13, 10, 26, 10];
  for (let i = 0; i < sig.length; i++) if (bytes[i] !== sig[i]) return null;
  // IHDR is first chunk; width/height at fixed offsets
  const w =
    (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
  const h =
    (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
  return { width: w >>> 0, height: h >>> 0 };
}

function gifDimensions(
  bytes: Uint8Array,
): { width: number; height: number } | null {
  if (bytes.length < 10) return null;
  const header = decodeUtf8(bytes.subarray(0, 6));
  if (header !== "GIF87a" && header !== "GIF89a") return null;
  const w = bytes[6] | (bytes[7] << 8);
  const h = bytes[8] | (bytes[9] << 8);
  return { width: w, height: h };
}

async function validateRasterDimensions(
  absPath: string,
  expected: [number, number],
): Promise<{
  ok: boolean;
  actual?: [number, number];
  kind?: "png" | "gif" | "unknown";
}> {
  const bytes = await readFileBytes(absPath);
  const png = pngDimensions(bytes);
  if (png) {
    const actual: [number, number] = [png.width, png.height];
    return {
      ok: png.width === expected[0] && png.height === expected[1],
      actual,
      kind: "png",
    };
  }
  const gif = gifDimensions(bytes);
  if (gif) {
    const actual: [number, number] = [gif.width, gif.height];
    return {
      ok: gif.width === expected[0] && gif.height === expected[1],
      actual,
      kind: "gif",
    };
  }
  return { ok: false, kind: "unknown" };
}

type ImageSpec = {
  jsonPath: string;
  ref: string;
  kind:
    | "pluginIcon"
    | "categoryIcon"
    | "actionIcon"
    | "stateImage"
    | "multiActionImage"
    | "encoderIcon"
    | "encoderBackground";
};

function imageRules(kind: ImageSpec["kind"]): {
  allowedExts: string[];
  dims?: ExpectedDims;
  rasterTwoX: boolean;
} {
  switch (kind) {
    case "pluginIcon":
      return {
        allowedExts: [".png"],
        dims: { base: [256, 256], twoX: [512, 512] },
        rasterTwoX: true,
      };
    case "categoryIcon":
      return {
        allowedExts: [".png", ".svg"],
        dims: { base: [28, 28], twoX: [56, 56] },
        rasterTwoX: true,
      };
    case "actionIcon":
      return {
        allowedExts: [".png", ".svg"],
        dims: { base: [20, 20], twoX: [40, 40] },
        rasterTwoX: true,
      };
    case "stateImage":
      return {
        allowedExts: [".png", ".gif", ".svg"],
        dims: { base: [72, 72], twoX: [144, 144] },
        rasterTwoX: true,
      };
    case "multiActionImage":
      return {
        allowedExts: [".png", ".svg"],
        dims: { base: [72, 72], twoX: [144, 144] },
        rasterTwoX: true,
      };
    case "encoderIcon":
      return {
        allowedExts: [".png", ".svg"],
        dims: { base: [72, 72], twoX: [144, 144] },
        rasterTwoX: true,
      };
    case "encoderBackground":
      return {
        allowedExts: [".png", ".svg"],
        dims: { base: [200, 100], twoX: [400, 200] },
        rasterTwoX: true,
      };
  }
}

async function validateImageRef(
  rootDir: string,
  spec: ImageSpec,
): Promise<Finding[]> {
  const findings: Finding[] = [];
  const { allowedExts, dims, rasterTwoX } = imageRules(spec.kind);

  const ref = spec.ref;
  if (typeof ref !== "string" || !ref) {
    findings.push({
      level: "error",
      code: "asset.invalid_ref",
      message: "Image reference is empty",
      path: spec.jsonPath,
    });
    return findings;
  }

  if (ref.includes("\\")) {
    findings.push({
      level: "error",
      code: "asset.path_backslash",
      message:
        "Backslashes are not allowed in manifest paths; use forward slashes.",
      path: spec.jsonPath,
    });
  }

  if (isDisallowedPathFragment(ref)) {
    findings.push({
      level: "error",
      code: "asset.path_disallowed",
      message:
        "Manifest path must be relative and must not traverse parent directories.",
      path: spec.jsonPath,
    });
    return findings;
  }

  if (!looksLikeExtensionlessRef(ref)) {
    findings.push({
      level: "error",
      code: "asset.extension_present",
      message: "This manifest image path must omit the file extension.",
      path: spec.jsonPath,
      hint: "Remove the extension and provide the file on disk with the expected extension(s).",
    });
    // Continue; still try to validate existence as-is.
  }

  // Find matching file(s)
  const candidates: { ext: string; base: string; twoX?: string }[] = [];
  for (const ext of allowedExts) {
    const base = joinManifestPath(rootDir, `${ref}${ext}`);
    if (ext === ".png" || ext === ".gif") {
      const twoX = joinManifestPath(rootDir, `${ref}@2x${ext}`);
      candidates.push({ ext, base, twoX });
    } else {
      candidates.push({ ext, base });
    }
  }

  const existing = [] as { ext: string; base: string; twoX?: string }[];
  for (const c of candidates) {
    if (await fileExists(c.base)) existing.push(c);
  }

  if (existing.length === 0) {
    findings.push({
      level: "error",
      code: "asset.missing",
      message: `Missing image file for ${spec.kind}: expected one of ${allowedExts.map((e) => `${ref}${e}`).join(", ")}`,
      path: spec.jsonPath,
    });
    return findings;
  }

  if (existing.length > 1) {
    findings.push({
      level: "warning",
      code: "asset.ambiguous",
      message: `Multiple image formats exist for the same reference (${ref}). Stream Deck may pick an unexpected one.`,
      path: spec.jsonPath,
    });
  }

  // Prefer SVG if present, otherwise PNG, otherwise GIF.
  const pick =
    existing.find((e) => e.ext === ".svg") ??
    existing.find((e) => e.ext === ".png") ??
    existing[0];

  // If raster, require @2x.
  const isRaster = pick.ext === ".png" || pick.ext === ".gif";
  if (isRaster && rasterTwoX && pick.twoX) {
    if (!(await fileExists(pick.twoX))) {
      findings.push({
        level: "error",
        code: "asset.missing_2x",
        message: `Missing @2x image: expected ${ref}@2x${pick.ext}`,
        path: spec.jsonPath,
      });
    }
  }

  // Dimension checks for raster only.
  if (isRaster && dims) {
    const baseOk = await validateRasterDimensions(pick.base, dims.base);
    if (!baseOk.ok) {
      const actual = baseOk.actual ? dimsToString(baseOk.actual) : "unknown";
      findings.push({
        level: "error",
        code: "asset.dimensions",
        message: `Wrong ${pick.ext.slice(1).toUpperCase()} dimensions for ${ref}${pick.ext}: got ${actual}, expected ${dimsToString(dims.base)}`,
        path: spec.jsonPath,
      });
    }

    if (pick.twoX && (await fileExists(pick.twoX)) && dims.twoX) {
      const twoOk = await validateRasterDimensions(pick.twoX, dims.twoX);
      if (!twoOk.ok) {
        const actual = twoOk.actual ? dimsToString(twoOk.actual) : "unknown";
        findings.push({
          level: "error",
          code: "asset.dimensions_2x",
          message: `Wrong ${pick.ext.slice(1).toUpperCase()} dimensions for ${ref}@2x${pick.ext}: got ${actual}, expected ${dimsToString(dims.twoX)}`,
          path: spec.jsonPath,
        });
      }
    }
  }

  return findings;
}

async function validateFilePath(
  rootDir: string,
  jsonPath: string,
  rel: string,
  allowedExts?: string[],
): Promise<Finding[]> {
  const findings: Finding[] = [];
  if (typeof rel !== "string" || !rel) {
    findings.push({
      level: "error",
      code: "asset.invalid_path",
      message: "Path is empty",
      path: jsonPath,
    });
    return findings;
  }

  if (rel.includes("\\")) {
    findings.push({
      level: "error",
      code: "asset.path_backslash",
      message:
        "Backslashes are not allowed in manifest paths; use forward slashes.",
      path: jsonPath,
    });
  }

  if (isDisallowedPathFragment(rel)) {
    findings.push({
      level: "error",
      code: "asset.path_disallowed",
      message:
        "Manifest path must be relative and must not traverse parent directories.",
      path: jsonPath,
    });
    return findings;
  }

  if (allowedExts && allowedExts.length > 0) {
    const ext = extname(rel).toLowerCase();
    if (!allowedExts.includes(ext)) {
      findings.push({
        level: "error",
        code: "asset.extension_invalid",
        message: `File extension must be one of: ${allowedExts.join(", ")}`,
        path: jsonPath,
      });
    }
  }

  const abs = joinManifestPath(rootDir, rel);
  if (!(await fileExists(abs))) {
    findings.push({
      level: "error",
      code: "asset.missing",
      message: `Missing file: ${rel}`,
      path: jsonPath,
    });
  }

  return findings;
}

export async function validateAssets(
  manifest: unknown,
  manifestPath: string,
): Promise<{ errors: Finding[]; warnings: Finding[] }> {
  const errors: Finding[] = [];
  const warnings: Finding[] = [];

  if (!isPlainObject(manifest)) {
    errors.push({
      level: "error",
      code: "manifest.not_object",
      message: "Manifest root must be an object",
      path: "$",
    });
    return { errors, warnings };
  }

  const rootDir = dirname(manifestPath);

  // Plugin-level file paths
  if (typeof manifest.CodePath === "string") {
    errors.push(
      ...(await validateFilePath(rootDir, "$.CodePath", manifest.CodePath)),
    );
  }
  if (typeof manifest.CodePathMac === "string") {
    errors.push(
      ...(await validateFilePath(
        rootDir,
        "$.CodePathMac",
        manifest.CodePathMac,
      )),
    );
  }
  if (typeof manifest.CodePathWin === "string") {
    errors.push(
      ...(await validateFilePath(
        rootDir,
        "$.CodePathWin",
        manifest.CodePathWin,
      )),
    );
  }
  if (typeof manifest.PropertyInspectorPath === "string") {
    errors.push(
      ...(await validateFilePath(
        rootDir,
        "$.PropertyInspectorPath",
        manifest.PropertyInspectorPath,
        [".html", ".htm"],
      )),
    );
  }

  // Plugin icon(s)
  if (typeof manifest.Icon === "string") {
    const f = await validateImageRef(rootDir, {
      jsonPath: "$.Icon",
      ref: manifest.Icon,
      kind: "pluginIcon",
    });
    for (const x of f) (x.level === "error" ? errors : warnings).push(x);
  }

  if (typeof manifest.CategoryIcon === "string") {
    const f = await validateImageRef(rootDir, {
      jsonPath: "$.CategoryIcon",
      ref: manifest.CategoryIcon,
      kind: "categoryIcon",
    });
    for (const x of f) (x.level === "error" ? errors : warnings).push(x);
  }

  // OS array sanity: duplicate Platform entries
  if (Array.isArray(manifest.OS)) {
    const seen = new Set<string>();
    for (let i = 0; i < manifest.OS.length; i++) {
      const os = manifest.OS[i];
      if (isPlainObject(os) && typeof os.Platform === "string") {
        if (seen.has(os.Platform)) {
          warnings.push({
            level: "warning",
            code: "manifest.duplicate_os",
            message: `Duplicate OS platform entry: ${os.Platform}`,
            path: `$.OS[${i}].Platform`,
          });
        }
        seen.add(os.Platform);
      }
    }
  }

  // Actions
  const actionUuidIndex = new Map<string, number>();
  if (Array.isArray(manifest.Actions)) {
    for (let i = 0; i < manifest.Actions.length; i++) {
      const action = manifest.Actions[i];
      const base = `$.Actions[${i}]`;
      if (!isPlainObject(action)) {
        errors.push({
          level: "error",
          code: "manifest.action_not_object",
          message: "Action must be an object",
          path: base,
        });
        continue;
      }

      // UUID uniqueness
      if (typeof action.UUID === "string") {
        const prev = actionUuidIndex.get(action.UUID);
        if (prev !== undefined) {
          errors.push({
            level: "error",
            code: "manifest.duplicate_action_uuid",
            message: `Duplicate action UUID: ${action.UUID} (also used at Actions[${prev}])`,
            path: `${base}.UUID`,
          });
        } else {
          actionUuidIndex.set(action.UUID, i);
        }

        if (
          typeof manifest.UUID === "string" &&
          !action.UUID.startsWith(`${manifest.UUID}.`)
        ) {
          warnings.push({
            level: "warning",
            code: "manifest.action_uuid_prefix",
            message: `Action UUID should usually start with the plugin UUID (expected prefix: ${manifest.UUID}.)`,
            path: `${base}.UUID`,
          });
        }
      }

      // Action icon
      if (typeof action.Icon === "string") {
        const f = await validateImageRef(rootDir, {
          jsonPath: `${base}.Icon`,
          ref: action.Icon,
          kind: "actionIcon",
        });
        for (const x of f) (x.level === "error" ? errors : warnings).push(x);
      }

      // Action-level PI path
      if (typeof action.PropertyInspectorPath === "string") {
        errors.push(
          ...(await validateFilePath(
            rootDir,
            `${base}.PropertyInspectorPath`,
            action.PropertyInspectorPath,
            [".html", ".htm"],
          )),
        );
      }

      // Encoder assets
      if (isPlainObject(action.Encoder)) {
        const encBase = `${base}.Encoder`;
        const controllers = Array.isArray(action.Controllers)
          ? new Set(
              action.Controllers.filter(
                (x) => typeof x === "string",
              ) as string[],
            )
          : null;

        if (
          controllers &&
          controllers.has("Encoder") &&
          !isPlainObject(action.Encoder)
        ) {
          warnings.push({
            level: "warning",
            code: "manifest.encoder_missing",
            message:
              "Controllers includes 'Encoder' but Encoder object is missing.",
            path: `${base}.Controllers`,
          });
        }

        if (typeof action.Encoder.Icon === "string") {
          const f = await validateImageRef(rootDir, {
            jsonPath: `${encBase}.Icon`,
            ref: action.Encoder.Icon,
            kind: "encoderIcon",
          });
          for (const x of f) (x.level === "error" ? errors : warnings).push(x);
        }
        if (typeof action.Encoder.background === "string") {
          const f = await validateImageRef(rootDir, {
            jsonPath: `${encBase}.background`,
            ref: action.Encoder.background,
            kind: "encoderBackground",
          });
          for (const x of f) (x.level === "error" ? errors : warnings).push(x);
        }
        if (
          typeof action.Encoder.layout === "string" &&
          action.Encoder.layout.endsWith(".json")
        ) {
          errors.push(
            ...(await validateFilePath(
              rootDir,
              `${encBase}.layout`,
              action.Encoder.layout,
              [".json"],
            )),
          );
        }
      }

      // States
      if (Array.isArray(action.States)) {
        for (let s = 0; s < action.States.length; s++) {
          const state = action.States[s];
          const stateBase = `${base}.States[${s}]`;
          if (!isPlainObject(state)) {
            errors.push({
              level: "error",
              code: "manifest.state_not_object",
              message: "State must be an object",
              path: stateBase,
            });
            continue;
          }

          if (typeof state.Image === "string") {
            const f = await validateImageRef(rootDir, {
              jsonPath: `${stateBase}.Image`,
              ref: state.Image,
              kind: "stateImage",
            });
            for (const x of f)
              (x.level === "error" ? errors : warnings).push(x);
          }

          if (typeof state.MultiActionImage === "string") {
            const f = await validateImageRef(rootDir, {
              jsonPath: `${stateBase}.MultiActionImage`,
              ref: state.MultiActionImage,
              kind: "multiActionImage",
            });
            for (const x of f)
              (x.level === "error" ? errors : warnings).push(x);
          }
        }
      }
    }
  }

  return { errors, warnings };
}

// ----------------------------
// Formatting / normalization
// ----------------------------

const ROOT_KEY_ORDER = [
  "$schema",
  "Name",
  "UUID",
  "Version",
  "Author",
  "Description",
  "URL",
  "SupportURL",
  "Icon",
  "Category",
  "CategoryIcon",
  "CodePath",
  "CodePathMac",
  "CodePathWin",
  "PropertyInspectorPath",
  "DefaultWindowSize",
  "Nodejs",
  "Software",
  "OS",
  "Profiles",
  "ApplicationsToMonitor",
  "Actions",
];

const ACTION_KEY_ORDER = [
  "Name",
  "UUID",
  "Icon",
  "Tooltip",
  "Controllers",
  "OS",
  "PropertyInspectorPath",
  "SupportedInKeyLogicActions",
  "SupportedInMultiActions",
  "VisibleInActionsList",
  "UserTitleEnabled",
  "DisableAutomaticStates",
  "DisableCaching",
  "SupportURL",
  "Encoder",
  "States",
];

const STATE_KEY_ORDER = [
  "Name",
  "Image",
  "MultiActionImage",
  "Title",
  "ShowTitle",
  "TitleAlignment",
  "TitleColor",
  "FontFamily",
  "FontSize",
  "FontStyle",
  "FontUnderline",
];

function stableSortKeys(
  obj: Record<string, unknown>,
  preferred: string[],
): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  const keys = Object.keys(obj);
  const preferredSet = new Set(preferred);

  for (const k of preferred) {
    if (k in obj) out[k] = normalizeValue(obj[k], k);
  }

  const rest = keys
    .filter((k) => !preferredSet.has(k))
    .sort((a, b) => a.localeCompare(b));
  for (const k of rest) out[k] = normalizeValue(obj[k], k);
  return out;
}

function normalizeValue(value: unknown, keyHint?: string): unknown {
  if (Array.isArray(value)) {
    return value.map((v) => normalizeValue(v));
  }
  if (isPlainObject(value)) {
    if (keyHint === "Actions") {
      return value as any; // handled where array items are processed
    }
    return stableSortKeys(value, []);
  }
  return value;
}

export function formatManifestObject(manifest: unknown): unknown {
  if (!isPlainObject(manifest)) return manifest;

  const out: Record<string, unknown> = {};

  // Root ordering
  const root = stableSortKeys(manifest, ROOT_KEY_ORDER);

  // Special handling for Actions and their nested objects
  if (Array.isArray((root as any).Actions)) {
    const actions = (root as any).Actions as unknown[];
    (root as any).Actions = actions.map((a) => {
      if (!isPlainObject(a)) return a;
      const action = stableSortKeys(a, ACTION_KEY_ORDER);
      if (Array.isArray((action as any).States)) {
        const states = (action as any).States as unknown[];
        (action as any).States = states.map((s) => {
          if (!isPlainObject(s)) return s;
          return stableSortKeys(s, STATE_KEY_ORDER);
        });
      }
      if (isPlainObject((action as any).Encoder)) {
        (action as any).Encoder = stableSortKeys((action as any).Encoder, [
          "Icon",
          "background",
          "layout",
          "StackColor",
          "TriggerDescription",
        ]);
      }
      return action;
    });
  }

  // OS ordering
  if (Array.isArray((root as any).OS)) {
    (root as any).OS = ((root as any).OS as unknown[]).map((o) => {
      if (!isPlainObject(o)) return o;
      return stableSortKeys(o, ["Platform", "MinimumVersion"]);
    });
  }

  // Put everything into out
  for (const [k, v] of Object.entries(root)) out[k] = v;
  return out;
}

export function stringifyJson(value: unknown): string {
  return JSON.stringify(value, null, 2) + "\n";
}

// ----------------------------
// Scaffolding
// ----------------------------

function slugify(input: string): string {
  return (
    input
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 64) || "action"
  );
}

function crc32Table(): Uint32Array {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[i] = c >>> 0;
  }
  return table;
}

const CRC_TABLE = crc32Table();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) >>> 0;
}

function u32be(n: number): Uint8Array {
  const b = new Uint8Array(4);
  b[0] = (n >>> 24) & 0xff;
  b[1] = (n >>> 16) & 0xff;
  b[2] = (n >>> 8) & 0xff;
  b[3] = n & 0xff;
  return b;
}

function pngChunk(type: string, data: Uint8Array): Uint8Array {
  const typeBytes = encodeUtf8(type);
  const len = u32be(data.length);
  const crcInput = new Uint8Array(typeBytes.length + data.length);
  crcInput.set(typeBytes, 0);
  crcInput.set(data, typeBytes.length);
  const crc = u32be(crc32(crcInput));

  const out = new Uint8Array(4 + 4 + data.length + 4);
  out.set(len, 0);
  out.set(typeBytes, 4);
  out.set(data, 8);
  out.set(crc, 8 + data.length);
  return out;
}

export function createTransparentPng(
  width: number,
  height: number,
): Uint8Array {
  // PNG signature
  const sig = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);

  // IHDR
  const ihdr = new Uint8Array(13);
  ihdr.set(u32be(width), 0);
  ihdr.set(u32be(height), 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace

  // Raw image data (filter byte 0 + RGBA pixels)
  const rowLen = 1 + width * 4;
  const raw = new Uint8Array(rowLen * height);
  // All zeros => fully transparent
  // Ensure filter bytes are 0 (already)

  // PNG expects zlib-wrapped DEFLATE
  const compressed = deflateSync(raw);
  const idatData = new Uint8Array(
    compressed.buffer,
    compressed.byteOffset,
    compressed.byteLength,
  );

  const chunks = [
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", idatData),
    pngChunk("IEND", new Uint8Array()),
  ];

  const total = sig.length + chunks.reduce((s, c) => s + c.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  out.set(sig, off);
  off += sig.length;
  for (const c of chunks) {
    out.set(c, off);
    off += c.length;
  }
  return out;
}

export function svgPlaceholder(
  viewBoxW: number,
  viewBoxH: number,
  label: string,
): string {
  const safe = label.replace(/[<>]/g, "");
  return (
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${viewBoxW} ${viewBoxH}">\n` +
    `  <rect x="0" y="0" width="${viewBoxW}" height="${viewBoxH}" fill="none" stroke="#FFFFFF" stroke-width="4"/>\n` +
    `  <text x="50%" y="50%" dominant-baseline="middle" text-anchor="middle" fill="#FFFFFF" font-size="${Math.max(12, Math.floor(viewBoxW / 10))}" font-family="Arial, sans-serif">${safe}</text>\n` +
    `</svg>\n`
  );
}

export type InitOptions = {
  dir: string;
  name: string;
  uuid: string;
  author: string;
  description: string;
  category?: string;
  softwareMinVersion?: string;
  sdkVersion?: number;
};

export async function scaffoldPlugin(opts: InitOptions): Promise<void> {
  const pluginDir = opts.dir;
  await ensureDir(pluginDir);

  const assetsDir = join(pluginDir, "assets");
  const binDir = join(pluginDir, "bin");
  await ensureDir(assetsDir);
  await ensureDir(binDir);

  // Plugin icons (PNG required)
  const pluginIconBase = "assets/plugin-icon";
  await Deno.writeFile(
    join(pluginDir, "assets", "plugin-icon.png"),
    createTransparentPng(256, 256),
  );
  await Deno.writeFile(
    join(pluginDir, "assets", "plugin-icon@2x.png"),
    createTransparentPng(512, 512),
  );

  // Category icon (SVG placeholder)
  const categoryIconBase = "assets/category-icon";
  await Deno.writeTextFile(
    join(pluginDir, "assets", "category-icon.svg"),
    svgPlaceholder(56, 56, "CAT"),
  );

  // Code stub
  const codePath = "bin/plugin.js";
  const codeAbs = join(pluginDir, "bin", "plugin.js");
  if (!(await fileExists(codeAbs))) {
    await Deno.writeTextFile(
      codeAbs,
      `// Stream Deck plugin entry point (stub)\n// Replace with real implementation.\nconsole.log('Plugin started');\n`,
    );
  }

  // Default action scaffold
  const actionName = "Action";
  const actionSlug = "action";
  const actionUuid = `${opts.uuid}.${actionSlug}`;

  const actionAssetsDir = join(pluginDir, "assets", "actions", actionSlug);
  await ensureDir(actionAssetsDir);

  const actionIconBase = `assets/actions/${actionSlug}/icon`;
  const stateImageBase = `assets/actions/${actionSlug}/state0`;
  const piRel = `assets/actions/${actionSlug}/pi.html`;

  await Deno.writeTextFile(
    join(pluginDir, "assets", "actions", actionSlug, "icon.svg"),
    svgPlaceholder(40, 40, "A"),
  );
  await Deno.writeTextFile(
    join(pluginDir, "assets", "actions", actionSlug, "state0.svg"),
    svgPlaceholder(144, 144, "S0"),
  );
  await Deno.writeTextFile(
    join(pluginDir, "assets", "actions", actionSlug, "pi.html"),
    `<!doctype html>\n<html>\n<head>\n  <meta charset=\"utf-8\"/>\n  <title>${actionName} - Property Inspector</title>\n</head>\n<body>\n  <h3>${actionName}</h3>\n  <p>Property inspector stub.</p>\n</body>\n</html>\n`,
  );

  const manifest = {
    $schema: "https://schemas.elgato.com/streamdeck/plugins/manifest.json",
    Name: opts.name,
    UUID: opts.uuid,
    Version: "1.0.0.0",
    Author: opts.author,
    Description: opts.description,
    Icon: pluginIconBase,
    Category: opts.category ?? opts.name,
    CategoryIcon: categoryIconBase,
    CodePath: codePath,
    SDKVersion: opts.sdkVersion ?? 3,
    Software: {
      MinimumVersion: opts.softwareMinVersion ?? "6.6",
    },
    OS: [
      { Platform: "mac", MinimumVersion: "13" },
      { Platform: "windows", MinimumVersion: "10" },
    ],
    Actions: [
      {
        Name: actionName,
        UUID: actionUuid,
        Icon: actionIconBase,
        States: [{ Image: stateImageBase }],
        PropertyInspectorPath: piRel,
      },
    ],
  };

  const formatted = formatManifestObject(manifest);
  await Deno.writeTextFile(
    join(pluginDir, "manifest.json"),
    stringifyJson(formatted),
  );
}

export type AddActionOptions = {
  manifestPath: string;
  name: string;
  uuid?: string;
};

export async function addActionToManifest(
  opts: AddActionOptions,
): Promise<void> {
  const { parsed, rawText } = await readAndParseManifestFile(opts.manifestPath);
  if (parsed.parseError || rawText === null) {
    throw new Error(
      `Failed to read/parse manifest: ${parsed.parseError ?? "unknown error"}`,
    );
  }
  if (!isPlainObject(parsed.value))
    throw new Error("Manifest root is not an object");

  const manifest = parsed.value as Record<string, any>;
  const pluginUuid = typeof manifest.UUID === "string" ? manifest.UUID : "";

  const slug = slugify(opts.name);
  const actionUuid = opts.uuid ?? (pluginUuid ? `${pluginUuid}.${slug}` : slug);

  if (!Array.isArray(manifest.Actions)) manifest.Actions = [];

  if (
    manifest.Actions.some((a: any) => isPlainObject(a) && a.UUID === actionUuid)
  ) {
    throw new Error(`Action UUID already exists in manifest: ${actionUuid}`);
  }

  const rootDir = dirname(opts.manifestPath);
  const actionDir = join(rootDir, "assets", "actions", slug);
  await ensureDir(actionDir);

  const iconBase = `assets/actions/${slug}/icon`;
  const stateBase = `assets/actions/${slug}/state0`;
  const piRel = `assets/actions/${slug}/pi.html`;

  await Deno.writeTextFile(
    join(actionDir, "icon.svg"),
    svgPlaceholder(40, 40, "A"),
  );
  await Deno.writeTextFile(
    join(actionDir, "state0.svg"),
    svgPlaceholder(144, 144, "S0"),
  );
  await Deno.writeTextFile(
    join(actionDir, "pi.html"),
    `<!doctype html>\n<html>\n<head><meta charset=\"utf-8\"/><title>${opts.name}</title></head>\n<body><h3>${opts.name}</h3><p>Property inspector stub.</p></body>\n</html>\n`,
  );

  manifest.Actions.push({
    Name: opts.name,
    UUID: actionUuid,
    Icon: iconBase,
    States: [{ Image: stateBase }],
    PropertyInspectorPath: piRel,
  });

  const formatted = formatManifestObject(manifest);
  await Deno.writeTextFile(opts.manifestPath, stringifyJson(formatted));
}

// ----------------------------
// High-level orchestrator
// ----------------------------

export async function runFullValidation(
  opts: ValidateOptions,
): Promise<ValidationResult> {
  const cacheDir =
    opts.cacheDir ??
    join(dirname(opts.manifestPath), ".cache", "streamdeck-schemas");

  const read = await readAndParseManifestFile(opts.manifestPath);
  const parsed = read.parsed;

  const errors: Finding[] = [];
  const warnings: Finding[] = [];

  if (parsed.parseError || read.rawText === null) {
    return {
      ok: false,
      errors: [
        {
          level: "error",
          code: "json.parse_failed",
          message: parsed.parseError ?? "Failed to read file",
        },
      ],
      warnings: [],
      meta: {
        schemaUrl:
          opts.schemaUrl ??
          "https://schemas.elgato.com/streamdeck/plugins/manifest.json",
        schemaFromCache: true,
        parsedAsJsonc: false,
      },
    };
  }

  // If the file is JSONC but user wants strict JSON, optionally rewrite.
  if (parsed.parsedAsJsonc) {
    warnings.push({
      level: "warning",
      code: "json.not_strict",
      message:
        "Manifest is not strict JSON (it parses as JSONC: comments/trailing commas). Stream Deck expects strict JSON.",
      path: "$",
    });

    if (opts.fixJsonc && opts.write) {
      await Deno.writeTextFile(
        opts.manifestPath,
        stringifyJson(formatManifestObject(parsed.value)),
      );
    }
  }

  // Determine schema URL.
  const manifestValue = parsed.value;
  const schemaUrl =
    opts.schemaUrl ??
    (isPlainObject(manifestValue) &&
    typeof (manifestValue as any).$schema === "string"
      ? (manifestValue as any).$schema
      : "https://schemas.elgato.com/streamdeck/plugins/manifest.json");

  // Schema validation.
  const schemaRes = await validateAgainstSchema(
    manifestValue,
    schemaUrl,
    cacheDir,
    opts.refreshSchema ?? false,
  );
  errors.push(...schemaRes.errors);
  warnings.push(...schemaRes.warnings);

  // Asset validation.
  if (opts.checkAssets !== false) {
    const assetRes = await validateAssets(manifestValue, opts.manifestPath);
    errors.push(...assetRes.errors);
    warnings.push(...assetRes.warnings);
  }

  const ok =
    errors.length === 0 &&
    (!opts.failOnWarn ||
      warnings.filter((w) => w.level === "warning").length === 0);

  return {
    ok,
    errors,
    warnings,
    meta: {
      schemaUrl,
      schemaFromCache: schemaRes.meta.schemaFromCache,
      parsedAsJsonc: parsed.parsedAsJsonc,
    },
  };
}

export async function formatManifestFile(
  manifestPath: string,
  write: boolean,
): Promise<string> {
  const { parsed, rawText } = await readAndParseManifestFile(manifestPath);
  if (parsed.parseError || rawText === null)
    throw new Error(parsed.parseError ?? "Failed to read file");
  const formatted = formatManifestObject(parsed.value);
  const text = stringifyJson(formatted);
  if (write) await Deno.writeTextFile(manifestPath, text);
  return text;
}
