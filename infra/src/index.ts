import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as cloudflare from "@pulumi/cloudflare";
import { machines } from "./inventory.js";
import { cloudflareAccountId } from "./account.js";
// Imported for its side effects: ./dns.ts declares the records for the machine domain,
// all of them derived from the inventory above.
import { machineDomain } from "./dns.js";
// Likewise for side effects: ./backup.ts declares the R2 bucket that holds restic
// backups, with its own credential and its own lifecycle -- deliberately sharing nothing
// with the nix-cache bucket below except the account.
import { resticRepositories, backupBucketName } from "./backup.js";

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
const cfAccountId = cloudflareAccountId;
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

// Make the cache actually cache. Measured before this rule, from a client in
// Germany (every request served by the LHR PoP):
//
//   GET <hash>.narinfo   cf-cache-status: DYNAMIC   200 in 180-750 ms
//                                                   404 in 500-2100 ms
//   GET nar/<hash>.nar.zst  cf-cache-status: MISS -> HIT
//
// The payload was already being cached and the metadata never was, because
// Cloudflare decides default cache eligibility by file extension / content
// type: `.zst` qualifies, `.narinfo` (content-type text/x-nix-narinfo) does
// not, so every single narinfo lookup went to the R2 origin. Against
// cache.nixos.org's 117-196 ms that is 4-9x, and a cold closure is thousands
// of narinfo lookups — see "Why a cold closure substitutes slowly" in AGENTS.md.
//
// THE 404s ARE DELIBERATELY NOT CACHED, and that is the whole design
// constraint. We push to this bucket continuously; if an edge-cached 404
// outlived a push, every other host would keep being told the path is absent
// and would rebuild it — which would make the cache worse than useless.
// `value: 0` is Cloudflare's "no-cache", so a miss is always revalidated
// against R2. We give up nothing real for that: within one substitution run
// Nix asks for each path exactly once, so negative caching would not have
// helped that run anyway.
//
// 200s get 30 days, matching Nix's own narinfo-cache-positive-ttl. Safe
// because store paths are content-addressed — a narinfo for a given hash never
// changes. The one thing that would break it is deleting objects from R2 while
// a client still holds a cached narinfo pointing at the NAR; nothing in this
// repo does that today, but that is the reason not to push this to a year.
//
// Scoped by http.host, so nothing else in schwetschke.dev is affected.
//
// NOTE: `http_request_cache_settings` is a phase entrypoint, and a zone can
// only have ONE. If the zone already has a cache ruleset created by hand, this
// will collide and must be imported instead of created — check `just
// pulumi-preview` before applying.
//
// The token needs **Cache & Performance -> Cache Settings -> Edit**, which is
// NOT implied by the "R2 admin + DNS edit" scope the rest of this file runs on,
// and is NOT the same as Zone Settings Write (the token had that and still got
// 403). Searching the token editor for "Cache Rules" finds nothing. Preview
// succeeds either way because it only reads; the apply fails with a 403 whose
// message is the actively misleading "Authentication error". See infra/README.md.
//
// Measured after applying, from the same client that produced the numbers above:
//   narinfo 200   MISS then HIT, 115-185 ms   (was 180-750 ms, never cached)
//   narinfo 404   MISS then DYNAMIC, never HIT, 231 ms mean over 10 distinct
//                 hashes (was 737-2122 ms)
// The 404 improvement was not predicted — the rule was expected to help hits
// only. Making the host cache-eligible evidently improves the miss path too.
// cache.nixos.org answers the same 404 in ~167 ms, so R2 is now level with it.
new cloudflare.Ruleset("nix-cache-caching", {
  zoneId: schwetschkeZone.zoneId,
  kind: "zone",
  phase: "http_request_cache_settings",
  name: "nix-cache edge caching",
  description: "Cache narinfo/nar for the Nix binary cache; never cache misses",
  rules: [
    {
      action: "set_cache_settings",
      description: "nix-cache: cache hits hard, always revalidate misses",
      enabled: true,
      expression: `(http.host eq "${cacheDomain}")`,
      actionParameters: {
        cache: true,
        edgeTtl: {
          mode: "override_origin",
          default: 2592000, // 30 days — immutable, content-addressed objects
          statusCodeTtls: [
            // 0 = no-cache. See the note above: a stale miss would defeat the
            // entire cache, so misses always go back to R2.
            { statusCode: 404, value: 0 },
            { statusCode: 403, value: 0 },
          ],
        },
        // Nothing here is fetched by a browser; leave the header to the origin
        // rather than let Cloudflare's 4 h default masquerade as our policy.
        browserTtl: { mode: "respect_origin" },
      },
    },
  ],
});

export const nixCacheUrl = `https://${cacheDomain}`;
export const nixCacheS3Endpoint = `https://${cfAccountId}.r2.cloudflarestorage.com`;

// --- Encrypted file backups (R2, restic) -----------------------------------
// Declared in ./backup.ts. Re-exported so the repository URL reaches
// infra/pulumi-outputs.json rather than being retyped into a shell command, where a
// typo would silently create a second, empty repository instead of failing.
export const resticBucket = backupBucketName;
export const resticRepos = resticRepositories;

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

// --- Machine inventory ------------------------------------------------------
// Not resources — see the header of ./inventory.ts for why the IONOS VPS cannot
// be one. Exported so it reaches infra/pulumi-outputs.json, the Pulumi->Nix
// contract in Architecture.md §6, and is therefore already present when the
// first NixOS host configuration lands (Plan.md Phase 3).
// Drift is checked by `just infra-verify`, not by `pulumi preview`.
//
// Importing it also runs the naming checks at the bottom of that file, so a name
// that does not fit the scheme in ../Naming.md fails `pulumi preview` here.
export const inventory = machines;

// The domain machines and internal services are named under. Anything published for
// humans lives in schwetschke.dev instead — see infra/Naming.md for why that split is
// technical (the FRITZ!Box rebind exception is granted per domain) rather than cosmetic.
export const machineZone = machineDomain;
