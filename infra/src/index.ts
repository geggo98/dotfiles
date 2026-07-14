import * as pulumi from "@pulumi/pulumi";
import * as cloudflare from "@pulumi/cloudflare";

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
