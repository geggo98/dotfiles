/**
 * The Cloudflare account everything here lives in.
 *
 * Not a secret -- it appears in the public R2 S3 endpoint hostname that both Macs and
 * the VPS already use as a substituter. Extracted into its own module only so `index.ts`
 * and `backup.ts` cannot drift apart on it.
 */
export const cloudflareAccountId = "81e63dbf073ca45ebf67c430beac09a4";

/** The S3-compatible endpoint for that account's R2 buckets. */
export const r2S3Endpoint = `https://${cloudflareAccountId}.r2.cloudflarestorage.com`;
