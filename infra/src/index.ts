import * as pulumi from "@pulumi/pulumi";
import { readSopsSecret } from "./helpers/sops.js";

// Export stack outputs
export const stack = pulumi.getStack();

// AWS credentials from SOPS (shared with nix-darwin)
const awsAccessKeyId = readSopsSecret("../secrets/secrets.enc.yaml", "aws-access-key-id");
const awsSecretAccessKey = readSopsSecret("../secrets/secrets.enc.yaml", "aws-secret-access-key");

// TODO: Phase 3 — add AWS S3 and IONOS resources here
