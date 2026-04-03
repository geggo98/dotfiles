import { execSync } from "child_process";
import * as path from "path";
import * as pulumi from "@pulumi/pulumi";

/**
 * Read a secret value from a SOPS-encrypted YAML file.
 * The value is marked as a Pulumi secret so it won't appear in plaintext in state or logs.
 *
 * Requires `sops` CLI to be available (provided by the nix devShell).
 */
export function readSopsSecret(
  sopsFile: string,
  key: string,
): pulumi.Output<string> {
  const resolved = path.resolve(import.meta.dirname, sopsFile);
  const value = execSync(`sops -d --extract '["${key}"]' '${resolved}'`, {
    encoding: "utf-8",
  }).trim();
  return pulumi.secret(value);
}
