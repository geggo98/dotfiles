import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as cloudflare from "@pulumi/cloudflare";
import { unmanagedHosts } from "./inventory.js";

// Export stack outputs
export const stack = pulumi.getStack();

// --- Cloudflare R2 binary cache -------------------------------------------
// The `nix-cache` bucket already exists (created by hand); Pulumi adopts it via
//   pulumi import cloudflare:index/r2Bucket:R2Bucket nix-cache \
//     '81e63dbf073ca45ebf67c430beac09a4/nix-cache/default'
// and manages the public custom domain that fronts it as a Nix substituter.
// Consumed by modules/nix-cache.nix (substituter = the custom domain; push =
// the S3 endpoint). Account ID is not a secret.
//
// The default cloudflare provider authenticates via the CLOUDFLARE_API_TOKEN
// env var, exported from secrets/infra.enc.yaml by the `just pulumi` wrapper.
// We use the default (not a named) provider so the CLI `pulumi import` below
// records the bucket under the same provider the code declares it with — a
// named provider would import under the default and mismatch on the next `up`.
const cfAccountId = "81e63dbf073ca45ebf67c430beac09a4";
const cacheDomain = "nix-cache.pub.schwetschke.dev";

const nixCacheBucket = new cloudflare.R2Bucket(
  "nix-cache",
  {
    accountId: cfAccountId,
    name: "nix-cache",
  },
  { protect: true },
);

const schwetschkeZone = cloudflare.getZoneOutput({
  filter: { name: "schwetschke.dev" },
});

// Publishes the bucket for public GET at the custom domain (no r2.dev rate
// limit; served through the Cloudflare CDN with caching).
new cloudflare.R2CustomDomain("nix-cache-domain", {
  accountId: cfAccountId,
  bucketName: nixCacheBucket.name,
  domain: cacheDomain,
  zoneId: schwetschkeZone.zoneId,
  enabled: true,
  minTls: "1.2",
});

export const nixCacheUrl = `https://${cacheDomain}`;
export const nixCacheS3Endpoint = `https://${cfAccountId}.r2.cloudflarestorage.com`;

// --- AWS S3 -----------------------------------------------------------------
// Both buckets predate this stack and were adopted, not created:
//   just pulumi import --file import.json --out generated.ts
// The code below is what that generator emitted, so it matches state exactly —
// `preview` must stay at zero changes. Do not "tidy" a property without checking
// the diff; each one is here because the live bucket has it.
//
// Two notes on shape, since both are easy to get wrong later:
//   * aws.s3.Bucket (not BucketV2) with inline `grants`/`policy`/`requestPayer`/
//     `serverSide…`. Provider v7 renamed the split resource back to `Bucket` and
//     still accepts these inline, which is what the import generator chose.
//     `preview` emits a deprecation warning for each of them, pointing at the
//     standalone aws.s3.BucketAcl / BucketPolicy / … resources. That migration is
//     a deliberate future change, not a tidy-up: it means removing the property
//     here and importing the standalone resource in the same step, or Pulumi
//     reads the absence as "delete this setting". Leave the warnings until then.
//   * `serverSideEncryptionConfiguration: AES256` is not a decision anyone made.
//     AWS applies SSE-S3 to every bucket by default since January 2023 and
//     reports it back, so it appears in state whether or not it was configured.
//   * The canonical user id in `grants` is the account owner. It is an ACL
//     identifier, not a credential — AWS publishes it for cross-account grants.
//
// Adoption only. Turning on versioning, or adding the public-access-block that
// `uipecod1` has and `ufute8ee-public` does not, are separate changes with their
// own blast radius; mixing them in here would destroy the zero-diff gate that
// proves the adoption itself was faithful.

// Deliberately world-readable — the name says so, and two independent mechanisms
// implement it: the bucket policy below (s3:GetObject for Principal "*") and a
// legacy ACL grant of READ to AllUsers. It has no public-access-block; that
// absence is what lets either mechanism take effect. Anything that adds one here
// takes the bucket offline, so treat this block as load-bearing.
const publicBucket = new aws.s3.Bucket("ufute8ee-public", {
  bucket: "ufute8ee-public",
  bucketNamespace: "global",
  grants: [
    {
      permissions: ["READ"],
      type: "Group",
      uri: "http://acs.amazonaws.com/groups/global/AllUsers",
    },
    {
      id: "6e5cb9499f8d4de3f18ab1b95fb186d1648a034b642a45fa5cb8284a11fe8f77",
      permissions: ["FULL_CONTROL"],
      type: "CanonicalUser",
    },
  ],
  policy: "{\"Statement\":[{\"Action\":\"s3:GetObject\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Resource\":\"arn:aws:s3:::ufute8ee-public/*\"}],\"Version\":\"2012-10-17\"}",
  region: "eu-central-1",
  requestPayer: "BucketOwner",
  serverSideEncryptionConfiguration: {
    rule: {
      applyServerSideEncryptionByDefault: {
        sseAlgorithm: "AES256",
      },
    },
  },
}, {
  protect: true,
});

// Private: all four public-access-block settings on, and ObjectOwnership
// BucketOwnerEnforced (ACLs disabled entirely). Neither is imported here — they
// are separate resources — so Pulumi will not touch them, but equally will not
// notice if they are turned off in the console. See README, "Hosts Pulumi cannot
// manage", for the same asymmetry stated generally.
const privateBucket = new aws.s3.Bucket("uipecod1", {
  bucket: "uipecod1",
  bucketNamespace: "global",
  grants: [{
    id: "6e5cb9499f8d4de3f18ab1b95fb186d1648a034b642a45fa5cb8284a11fe8f77",
    permissions: ["FULL_CONTROL"],
    type: "CanonicalUser",
  }],
  region: "eu-central-1",
  requestPayer: "BucketOwner",
  serverSideEncryptionConfiguration: {
    rule: {
      applyServerSideEncryptionByDefault: {
        sseAlgorithm: "AES256",
      },
    },
  },
}, {
  protect: true,
});

export const s3Buckets = {
  public: publicBucket.bucket,
  private: privateBucket.bucket,
};

// --- Inventory of hosts Pulumi does not provision ---------------------------
// Not resources — see the header of ./inventory.ts for why the IONOS VPS cannot
// be one. Exported so it reaches infra/pulumi-outputs.json, the Pulumi->Nix
// contract in Architecture.md §6, and is therefore already present when the
// first NixOS host configuration lands (Plan.md Phase 3).
// Drift is checked by `just infra-verify`, not by `pulumi preview`.
export const inventory = unmanagedHosts;
