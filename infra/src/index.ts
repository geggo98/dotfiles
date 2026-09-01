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
// The code below started as that generator's output and has since diverged. The
// generator emitted aws.s3.Bucket (not BucketV2 — provider v7 renamed the split
// resource back) carrying `grants`/`policy`/`requestPayer`/`serverSide…` inline,
// which it still accepts and which cost a deprecation warning apiece: seven
// across the two buckets. Those four now live in the eight standalone resources
// below, each adopted through a one-shot `import:` option — "8 imported, 20
// unchanged", nothing created — which was then removed again, as the SDK asks.
// The seven warnings are gone; `preview` reports 28 unchanged.
//
// `preview` must still stay at zero changes, but read that gate more narrowly
// than before. A bucket's PRIOR STATE carries these attributes whether or not
// the program declares them — measured: `uipecod1`, which has no bucket policy
// at all, records `policy: ""` — and that is what the provider diffs against.
// Zero diff therefore means "the provider wants to change nothing", not "state
// equals the program".
//
// Three notes, each of which cost a measurement:
//   * Removing a deprecated inline property does NOT read as "delete this
//     setting". This comment said it did, and so does the body of a63ad1c; both
//     were wrong, and the belief is why the split sat undone. Measured
//     01.09.2026: all four dropped at once, no `import:` left anywhere, gives 28
//     unchanged and no diff, twice in a row. Two independent reasons — the
//     attributes are Optional+Computed in Terraform, so ProposedNew restores the
//     prior value, and terraform-provider-aws >= 6.46.0 (vendored in plugin
//     7.40.0) gates every deprecated write in resourceBucketUpdate behind
//     deprecatedAttributeInRawConfig. One apply would have sufficed; the two
//     used here bought a smaller blast radius, not correctness.
//   * `serverSideEncryptionConfiguration: AES256` is not a decision anyone made.
//     AWS applies SSE-S3 to every bucket by default since January 2023 and
//     reports it back, so it appears in state whether or not it was configured.
//   * The canonical user id in the ACL is the account owner. It is an ACL
//     identifier, not a credential — AWS publishes it for cross-account grants.
//
// Nor is `protect: true` the safety net it looks like here: it blocks delete and
// replace, never update, so it would not have stopped an update that cleared a
// setting. What it does buy is that `bucket` is ForceNew on all eight resources
// below, so a typo becomes a replace, and protect turns that into a hard error
// instead of a delete-then-create.
//
// The split changed nothing on AWS: policy and ACL are byte-identical to a
// snapshot taken before it, and an anonymous GET against `ufute8ee-public` still
// answers 200. Turning on versioning, or giving `ufute8ee-public` the
// public-access-block that `uipecod1` has, remain separate changes with their own
// blast radius.
//
// Finally, a counter not to chase to zero: the four "using pulumi-resource-<aws|
// cloudflare> from $PATH at /nix/store/…" lines are Nix serving the plugins from
// the store rather than ~/.pulumi/plugins (573f106). They stay.

// Deliberately world-readable — the name says so, and two independent mechanisms
// implement it: the bucket policy below (s3:GetObject for Principal "*") and a
// legacy ACL grant of READ to AllUsers. It has no public-access-block; that
// absence is what lets either mechanism take effect. Anything that adds one here
// takes the bucket offline, so treat this block as load-bearing.
const publicBucket = new aws.s3.Bucket("ufute8ee-public", {
  bucket: "ufute8ee-public",
  bucketNamespace: "global",
  region: "eu-central-1",
}, {
  protect: true,
});

// The four settings the bucket above used to carry inline, as the separate
// resources the provider asks for. They were adopted, not created: each held an
// `import:` option for exactly one `up`, and the option was removed once that
// had run. A `create` in that first preview would have meant the read came back
// empty, and for the ACL or the policy that is the difference between adopting
// the bucket and briefly taking a world-readable one offline — so the gate was
// "8 to import, 0 to create", checked before applying. A `create` appearing here
// again would mean the state entry had been lost.
//
// `protect: true` on the ACL and the policy for the same reason the bucket has
// it: those two are what make it public, so deleting either is an outage.
const publicBucketAcl = new aws.s3.BucketAcl("ufute8ee-public-acl", {
  bucket: publicBucket.bucket,
  region: "eu-central-1",
  // Written in the order GetBucketAcl returns, owner first. The underlying
  // Terraform attribute is a set, so order carries no meaning — but matching
  // the read avoids a diff that looks real and is not.
  accessControlPolicy: {
    owner: {
      id: "6e5cb9499f8d4de3f18ab1b95fb186d1648a034b642a45fa5cb8284a11fe8f77",
    },
    grants: [
      {
        grantee: {
          id: "6e5cb9499f8d4de3f18ab1b95fb186d1648a034b642a45fa5cb8284a11fe8f77",
          type: "CanonicalUser",
        },
        permission: "FULL_CONTROL",
      },
      {
        grantee: {
          type: "Group",
          uri: "http://acs.amazonaws.com/groups/global/AllUsers",
        },
        permission: "READ",
      },
    ],
  },
}, {
  protect: true,
});

const publicBucketPolicy = new aws.s3.BucketPolicy("ufute8ee-public-policy", {
  bucket: publicBucket.bucket,
  region: "eu-central-1",
  // Byte-identical to the `policy` the bucket above used to carry inline: the two
  // coexisted in the program for one apply, and identical text was the cheapest
  // way to be sure they could not disagree. It is also already the
  // canonical form — the provider normalises policy JSON by round-tripping it
  // through a Go map, and Go marshals map keys sorted, which is exactly this
  // ordering. AWS returns Version first; that is the same document, but it would
  // only be normalised back to this.
  policy: "{\"Statement\":[{\"Action\":\"s3:GetObject\",\"Effect\":\"Allow\",\"Principal\":\"*\",\"Resource\":\"arn:aws:s3:::ufute8ee-public/*\"}],\"Version\":\"2012-10-17\"}",
}, {
  protect: true,
});

const publicBucketEncryption = new aws.s3.BucketServerSideEncryptionConfiguration("ufute8ee-public-sse", {
  bucket: publicBucket.bucket,
  region: "eu-central-1",
  rules: [{
    applyServerSideEncryptionByDefault: {
      sseAlgorithm: "AES256",
    },
  }],
});

const publicBucketRequestPayment = new aws.s3.BucketRequestPaymentConfiguration("ufute8ee-public-payer", {
  bucket: publicBucket.bucket,
  region: "eu-central-1",
  payer: "BucketOwner",
});

// Private: all four public-access-block settings on, and ObjectOwnership
// BucketOwnerEnforced (ACLs disabled entirely). Both are separate resources and
// both are adopted below, as `uipecod1-public-access-block` and
// `uipecod1-ownership`. README, "Hosts Pulumi cannot manage", states the same
// asymmetry generally; it still holds for what Pulumi cannot adopt at all — the
// IONOS VPS in src/inventory.ts — but no longer for these two.
const privateBucket = new aws.s3.Bucket("uipecod1", {
  bucket: "uipecod1",
  bucketNamespace: "global",
  region: "eu-central-1",
}, {
  protect: true,
});

// Same split as for the public bucket, minus the ACL. `uipecod1` has
// ObjectOwnership BucketOwnerEnforced, so ACLs are switched off entirely and
// PutBucketAcl answers AccessControlListNotSupported — an aws.s3.BucketAcl here
// could be imported and then never applied. The `grants` entry the import
// generator recorded is AWS reporting the owner back, not a setting anyone made,
// so it is dropped rather than ported.
const privateBucketEncryption = new aws.s3.BucketServerSideEncryptionConfiguration("uipecod1-sse", {
  bucket: privateBucket.bucket,
  region: "eu-central-1",
  rules: [{
    applyServerSideEncryptionByDefault: {
      sseAlgorithm: "AES256",
    },
  }],
});

const privateBucketRequestPayment = new aws.s3.BucketRequestPaymentConfiguration("uipecod1-payer", {
  bucket: privateBucket.bucket,
  region: "eu-central-1",
  payer: "BucketOwner",
});

// These two are what actually make the bucket private, and until this split
// Pulumi could not see them: it would not have touched them, but equally would
// not have noticed them being switched off in the console. Pure adoption —
// nothing about the live bucket changed.
//
// Deliberately not mirrored onto `ufute8ee-public`. Either one there takes it
// offline; see the comment above that bucket.
const privateBucketPublicAccessBlock = new aws.s3.BucketPublicAccessBlock("uipecod1-public-access-block", {
  bucket: privateBucket.bucket,
  region: "eu-central-1",
  blockPublicAcls: true,
  blockPublicPolicy: true,
  ignorePublicAcls: true,
  restrictPublicBuckets: true,
});

const privateBucketOwnership = new aws.s3.BucketOwnershipControls("uipecod1-ownership", {
  bucket: privateBucket.bucket,
  region: "eu-central-1",
  rule: {
    objectOwnership: "BucketOwnerEnforced",
  },
});

export const s3Buckets = {
  public: publicBucket.bucket,
  private: privateBucket.bucket,
};

// --- Machine inventory ------------------------------------------------------
// Not resources — see the header of ./inventory.ts for why the IONOS VPS cannot
// be one. Drift is checked by `just infra-verify`, not by `pulumi preview`.
//
// Be honest about what this export is and is not. It was written to feed
// infra/pulumi-outputs.json, the Pulumi->Nix contract in Architecture.md §6, so
// the data would be in place when the first NixOS host arrived. That host landed
// on 2026-08-17 and the contract was never built: addresses come from
// `deployTarget` in modules/nixos-wiring.nix instead. Nothing reads this stack
// output today — dns.ts imports ./inventory.js directly, and infra-verify.py
// reads inventory.ts itself by type-stripping. So it publishes the inventory into
// `pulumi stack output` for a human, and nothing more.
//
// The IMPORT above earns its place independently of the export, and that is the
// part not to remove by accident: it is what makes the naming checks run.
//
// Importing it also runs the naming checks at the bottom of that file, so a name
// that does not fit the scheme in ../Naming.md fails `pulumi preview` here.
export const inventory = machines;

// The domain machines and internal services are named under. Anything published for
// humans lives in schwetschke.dev instead — see infra/Naming.md for why that split is
// technical (the FRITZ!Box rebind exception is granted per domain) rather than cosmetic.
export const machineZone = machineDomain;
