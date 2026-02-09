#!/usr/bin/env -S deno run --lock streamdeck_manifest.deno.lock --allow-read --allow-write --allow-net

// Stream Deck manifest helper CLI
//
// Commands:
//   validate <manifest.json> [--schema <url>] [--refresh-schema] [--cache-dir <dir>] [--no-assets]
//                          [--fail-on-warn] [--fix-jsonc] [--write]
//   fmt      <manifest.json> [--write]
//   init     <pluginDir.sdPlugin> --name <name> --uuid <uuid> --author <author> --description <desc>
//                          [--category <cat>] [--min-version <ver>] [--sdk-version <n>]
//   add-action <manifest.json> --name <actionName> [--uuid <actionUuid>]
//
// Default output is JSON for machine consumption.

import {
  addActionToManifest,
  formatManifestFile,
  runFullValidation,
  scaffoldPlugin,
  type ValidationResult,
} from "./streamdeck_manifest_lib.ts";

function printHelp(): void {
  const txt =
    `Stream Deck manifest toolkit\n\n` +
    `Usage:\n` +
    `  streamdeck_manifest.ts validate <manifest.json> [--schema <url>] [--refresh-schema] [--cache-dir <dir>] [--no-assets] [--fail-on-warn] [--fix-jsonc] [--write]\n` +
    `  streamdeck_manifest.ts fmt <manifest.json> [--write]\n` +
    `  streamdeck_manifest.ts init <pluginDir.sdPlugin> --name <name> --uuid <uuid> --author <author> --description <desc> [--category <cat>] [--min-version <ver>] [--sdk-version <n>]\n` +
    `  streamdeck_manifest.ts add-action <manifest.json> --name <actionName> [--uuid <actionUuid>]\n` +
    `\nExamples:\n` +
    `  ./tools/streamdeck_manifest.ts validate ./MyPlugin.sdPlugin/manifest.json\n` +
    `  ./tools/streamdeck_manifest.ts validate ./MyPlugin.sdPlugin/manifest.json --fix-jsonc --write\n` +
    `  ./tools/streamdeck_manifest.ts fmt ./MyPlugin.sdPlugin/manifest.json --write\n` +
    `  ./tools/streamdeck_manifest.ts init ./MyPlugin.sdPlugin --name "My Plugin" --uuid com.example.myplugin --author "Example" --description "..."\n` +
    `  ./tools/streamdeck_manifest.ts add-action ./MyPlugin.sdPlugin/manifest.json --name "Toggle Mute"\n`;
  console.error(txt);
}

type ParsedArgs = {
  cmd: string | null;
  positionals: string[];
  flags: Record<string, string | boolean>;
};

function parseArgs(argv: string[]): ParsedArgs {
  if (argv.length === 0) return { cmd: null, positionals: [], flags: {} };

  const cmd = argv[0];
  const args = argv.slice(1);

  const flags: Record<string, string | boolean> = {};
  const positionals: string[] = [];

  const valueFlags = new Set([
    "schema",
    "cache-dir",
    "name",
    "uuid",
    "author",
    "description",
    "category",
    "min-version",
    "sdk-version",
  ]);

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--") {
      positionals.push(...args.slice(i + 1));
      break;
    }

    if (a === "-h" || a === "--help") {
      flags.help = true;
      continue;
    }

    if (a.startsWith("--")) {
      const raw = a.slice(2);
      const eq = raw.indexOf("=");
      if (eq >= 0) {
        const k = raw.slice(0, eq);
        const v = raw.slice(eq + 1);
        flags[k] = v;
        continue;
      }

      const k = raw;
      const next = args[i + 1];
      if (valueFlags.has(k) && next !== undefined && !next.startsWith("-")) {
        flags[k] = next;
        i++;
      } else {
        flags[k] = true;
      }
      continue;
    }

    // Support a tiny subset of short flags
    if (a === "-w") {
      flags.write = true;
      continue;
    }

    positionals.push(a);
  }

  return { cmd, positionals, flags };
}

function jsonOut(value: unknown): void {
  Deno.stdout.writeSync(
    new TextEncoder().encode(JSON.stringify(value, null, 2) + "\n"),
  );
}

function requireFlag(
  flags: Record<string, string | boolean>,
  name: string,
): string {
  const v = flags[name];
  if (typeof v !== "string" || v.length === 0) {
    throw new Error(`Missing required flag: --${name}`);
  }
  return v;
}

function flagString(
  flags: Record<string, string | boolean>,
  name: string,
): string | undefined {
  const v = flags[name];
  return typeof v === "string" ? v : undefined;
}

function flagBool(
  flags: Record<string, string | boolean>,
  name: string,
): boolean {
  return flags[name] === true;
}

function errorOut(message: string, details?: unknown): void {
  jsonOut({ ok: false, error: message, details });
}

async function cmdValidate(
  positionals: string[],
  flags: Record<string, string | boolean>,
): Promise<number> {
  const manifestPath = positionals[0];
  if (!manifestPath) throw new Error("validate requires <manifest.json>");

  const schemaUrl = flagString(flags, "schema");
  const refreshSchema = flagBool(flags, "refresh-schema");
  const cacheDir = flagString(flags, "cache-dir");
  const checkAssets = !flagBool(flags, "no-assets");
  const failOnWarn = flagBool(flags, "fail-on-warn");
  const fixJsonc = flagBool(flags, "fix-jsonc");
  const write = flagBool(flags, "write");

  const result: ValidationResult = await runFullValidation({
    manifestPath,
    schemaUrl,
    refreshSchema,
    cacheDir,
    checkAssets,
    failOnWarn,
    fixJsonc,
    write,
  });

  jsonOut(result);
  return result.ok ? 0 : 1;
}

async function cmdFmt(
  positionals: string[],
  flags: Record<string, string | boolean>,
): Promise<number> {
  const manifestPath = positionals[0];
  if (!manifestPath) throw new Error("fmt requires <manifest.json>");

  const write = flagBool(flags, "write");
  const text = await formatManifestFile(manifestPath, write);

  if (write) {
    jsonOut({ ok: true, written: true, path: manifestPath });
  } else {
    jsonOut({ ok: true, written: false, path: manifestPath, content: text });
  }
  return 0;
}

async function cmdInit(
  positionals: string[],
  flags: Record<string, string | boolean>,
): Promise<number> {
  const dir = positionals[0];
  if (!dir) throw new Error("init requires <pluginDir.sdPlugin>");

  const name = requireFlag(flags, "name");
  const uuid = requireFlag(flags, "uuid");
  const author = requireFlag(flags, "author");
  const description = requireFlag(flags, "description");

  const category = flagString(flags, "category");
  const minVersion = flagString(flags, "min-version");
  const sdkVersionStr = flagString(flags, "sdk-version");
  const sdkVersion = sdkVersionStr ? Number(sdkVersionStr) : undefined;
  if (sdkVersionStr && (Number.isNaN(sdkVersion) || sdkVersion <= 0)) {
    throw new Error("--sdk-version must be a positive number");
  }

  await scaffoldPlugin({
    dir,
    name,
    uuid,
    author,
    description,
    category,
    softwareMinVersion: minVersion,
    sdkVersion,
  });

  jsonOut({ ok: true, created: true, dir });
  return 0;
}

async function cmdAddAction(
  positionals: string[],
  flags: Record<string, string | boolean>,
): Promise<number> {
  const manifestPath = positionals[0];
  if (!manifestPath) throw new Error("add-action requires <manifest.json>");

  const name = requireFlag(flags, "name");
  const uuid = flagString(flags, "uuid");

  await addActionToManifest({ manifestPath, name, uuid });
  jsonOut({ ok: true, updated: true, path: manifestPath });
  return 0;
}

async function main(): Promise<void> {
  const parsed = parseArgs(Deno.args);
  if (!parsed.cmd || flagBool(parsed.flags, "help")) {
    printHelp();
    Deno.exit(parsed.cmd ? 0 : 2);
  }

  try {
    let code = 0;
    switch (parsed.cmd) {
      case "validate":
        code = await cmdValidate(parsed.positionals, parsed.flags);
        break;
      case "fmt":
        code = await cmdFmt(parsed.positionals, parsed.flags);
        break;
      case "init":
        code = await cmdInit(parsed.positionals, parsed.flags);
        break;
      case "add-action":
        code = await cmdAddAction(parsed.positionals, parsed.flags);
        break;
      default:
        printHelp();
        throw new Error(`Unknown command: ${parsed.cmd}`);
    }
    Deno.exit(code);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    errorOut(msg);
    Deno.exit(1);
  }
}

if (import.meta.main) {
  await main();
}
