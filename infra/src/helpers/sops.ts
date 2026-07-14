import { execSync } from "child_process";
import { existsSync } from "fs";
import * as path from "path";
import * as pulumi from "@pulumi/pulumi";

/**
 * Walk up from `start` to the Pulumi project directory (the one holding
 * `Pulumi.yaml`). Used to anchor secret paths: pulumi runs the program with
 * cwd = the compiled main's dir (`dist/`), and `import.meta.dirname` points at
 * `dist/helpers/`, so neither is the project root. Finding `Pulumi.yaml` works
 * for both the `src/` (ts-node) and `dist/` (compiled) layouts.
 */
function projectRoot(start: string): string {
  let dir = start;
  while (!existsSync(path.join(dir, "Pulumi.yaml"))) {
    const parent = path.dirname(dir);
    if (parent === dir) {
      throw new Error(`Pulumi.yaml not found above ${start}`);
    }
    dir = parent;
  }
  return dir;
}

/**
 * Read a secret value from a SOPS-encrypted YAML file.
 * The value is marked as a Pulumi secret so it won't appear in plaintext in state or logs.
 *
 * `sopsFile` is resolved relative to the Pulumi project directory (`infra/`),
 * so callers pass paths like `../secrets/secrets.enc.yaml` (repo-root/secrets).
 *
 * Requires `sops` CLI to be available (provided by the nix devShell).
 */
export function readSopsSecret(
  sopsFile: string,
  key: string,
): pulumi.Output<string> {
  const resolved = path.resolve(projectRoot(import.meta.dirname), sopsFile);
  const value = execSync(`sops -d --extract '["${key}"]' '${resolved}'`, {
    encoding: "utf-8",
  }).trim();
  return pulumi.secret(value);
}
