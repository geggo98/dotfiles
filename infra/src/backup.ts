/**
 * The R2 bucket that holds encrypted file backups, written by restic.
 *
 * First user is p-own-lengenwang-c5esve: ~803 GiB of Filme, Musik and eBooks that have
 * to leave that machine before its single NVMe is repartitioned, because boot-pool and
 * the data pool share one disk and a reinstall destroys both. See
 * ../machines/p-own-lengenwang-c5esve.md.
 *
 * **Separate bucket, separate credential, on purpose.** The `nix-cache` bucket next door
 * is written by a post-build-hook running as root on both Macs, so its token is present
 * on every workstation and is used by an automated process dozens of times a day. A
 * backup that may temporarily be the only copy of the data must not be reachable with
 * that credential. Nothing here shares anything with it but the account.
 *
 * **The provider never sees plaintext.** restic encrypts client-side (AES-256 + Poly1305)
 * with a repository password we hold; R2 stores opaque packs. The password lives in
 * sops *and* 1Password -- a restic repository without its password is mathematically
 * unrecoverable, which makes a single storage location for it the real risk, not the
 * bucket.
 */
import * as cloudflare from "@pulumi/cloudflare";
import { cloudflareAccountId, r2S3Endpoint } from "./account.js";

/** One bucket, one restic repository per host under its own prefix. */
const bucketName = "restic-backup";

/**
 * Repository prefixes, keyed by the machine the data comes from. Names come from
 * ../Naming.md, so a repository is traceable to a machine without a lookup table.
 */
export const resticPrefixes = {
  "p-own-lengenwang-c5esve": "p-own-lengenwang-c5esve",
} as const;

const backupBucket = new cloudflare.R2Bucket(
  "restic-backup",
  {
    accountId: cloudflareAccountId,
    name: bucketName,
    // Frankfurt. Same continent as both the source and the workstations; R2's egress is
    // free either way, so this is about latency on restore, not cost.
    location: "WEUR",
  },
  // The one resource in this repository whose accidental deletion is unrecoverable by
  // definition: it exists precisely for the window in which the source no longer does.
  { protect: true },
);

/**
 * Standard first, Infrequent Access later -- and the order is what saves money.
 *
 * IA is $0.01/GB-month against Standard's $0.015, but it also charges $0.01/GB to *read*.
 * `restic check --read-data` reads the entire repository back, which is the one operation
 * that must happen before the source is wiped. Uploading straight into IA would put a
 * ~$9 retrieval charge on exactly the step we care most about, and start the 30-day
 * minimum-duration clock during it. Writing to Standard, verifying while reads are free,
 * and letting the rule demote afterwards costs nothing extra.
 *
 * Scoped to `data/`, deliberately. restic keeps `config`, `index/`, `snapshots/` and
 * `keys/` small and touches them on every single operation; leaving that metadata in
 * Standard keeps routine work free and fast while the bulk -- the pack files, which are
 * read only during a restore or a full check -- goes cold.
 */
new cloudflare.R2BucketLifecycle("restic-backup-lifecycle", {
  accountId: cloudflareAccountId,
  bucketName: backupBucket.name,
  rules: Object.values(resticPrefixes).map((prefix) => ({
    id: `${prefix}-data-to-ia`,
    enabled: true,
    conditions: { prefix: `${prefix}/data/` },
    storageClassTransitions: [
      {
        condition: { type: "Age", maxAge: 30 * 24 * 3600 },
        storageClass: "InfrequentAccess",
      },
    ],
  })),
});

/**
 * Retention against accidental or malicious deletion, for the window in which this is
 * the only copy.
 *
 * **Scoped to `data/` for a reason that will not be obvious from the outside, and that
 * costs an afternoon to rediscover:** restic creates a lock object under `locks/` at the
 * start of every operation and deletes it at the end. A lock rule covering the whole
 * repository would block that deletion, so stale locks would accumulate and every
 * subsequent run would refuse with "repository is already locked" -- and `restic unlock`
 * could not help, because unlocking is itself a delete. Confining the rule to the pack
 * files leaves restic's own bookkeeping free while protecting the bytes that matter.
 *
 * 30 days rather than indefinite: long enough to outlive a mistake or a stolen
 * credential, short enough that the repository can eventually be pruned or retired
 * without a support ticket. Note this *does* mean `restic prune` cannot reclaim space
 * from packs younger than 30 days, which is intended during the migration and worth
 * revisiting once a second copy exists.
 *
 * R2 bucket locks are not S3 Object Lock: no compliance mode, no legal hold. They stop
 * accidents, not a determined attacker with account access.
 */
new cloudflare.R2BucketLock("restic-backup-lock", {
  accountId: cloudflareAccountId,
  bucketName: backupBucket.name,
  rules: Object.values(resticPrefixes).map((prefix) => ({
    id: `${prefix}-data-retention`,
    enabled: true,
    prefix: `${prefix}/data/`,
    condition: { type: "Age", maxAgeSeconds: 30 * 24 * 3600 },
  })),
});

/** Everything a restic invocation needs except the credentials and the password. */
export const resticRepositories = Object.fromEntries(
  Object.entries(resticPrefixes).map(([machine, prefix]) => [
    machine,
    `s3:${r2S3Endpoint}/${bucketName}/${prefix}`,
  ]),
);

export const backupBucketName = bucketName;
