# Simplified Technical English for IT Writing

This reference adapts the writing rules of ASD-STE100 Simplified Technical English to English IT texts: runbooks, READMEs, PR descriptions, tickets, review comments, commit bodies, and error messages. Load it when you write or review such texts and want checkable rules instead of taste.

Attribution: adapted from ASD-STE100 Simplified Technical English, Issue 9 (2025-01-15), published by the Aerospace, Security and Defence Industries Association of Europe (ASD). This file is an adaptation for IT writing, not a reproduction of the standard. The rule numbers cite the standard. The wording and all examples are original.

## 1. Words (STE 1.1-1.14)

STE limits writers to about 875 approved general words plus the technical nouns and technical verbs of their field. IT has no controlled dictionary, so adapt the idea: keep a small, consistent vocabulary, and treat the project glossary as the dictionary. When the glossary names a thing, that name wins.

Build sentences from plain common words plus the technical terms of your project (STE 1.1, 1.5, 1.12). Domain nouns such as "pod", "webhook", and "lockfile", and domain verbs such as "deploy", "rebase", and "merge" are the IT equivalent of STE technical nouns and technical verbs.

    Bad:  Utilize the fallback path to obviate the outage.
    Good: Use the fallback path to prevent the outage.

Use each word as one part of speech (STE 1.2). If the glossary defines "release" as the shipped version, keep it a noun.

    Bad:  Release the fix on Friday. The release contains ten commits.
    Good: Publish the fix on Friday. The release contains ten commits.

Give each word one meaning in a document (STE 1.3). A word that changes meaning mid-text forces the reader to guess.

    Bad:  The instance restarts when the parser creates a new instance.
    Good: The VM restarts when the parser creates a new object.

Use the standard forms of your verbs and adjectives (STE 1.4). Section 3 restricts the tenses.

    Bad:  The migration was ran twice and has broke replication.
    Good: The migration ran twice and broke replication.

Use the names that your project, vendor, or industry approves (STE 1.6, 1.8). Component names come from the code, the API docs, or the glossary, not from improvisation.

    Bad:  The Kubernetes brain moves the workload boxes to other machines.
    Good: The kube-scheduler moves the pods to other nodes.

Do not use nouns as verbs (STE 1.7). Product names and artifact names are the usual victims.

    Bad:  Ticket the regression and Slack me the link.
    Good: Create a ticket for the regression and send me the link on Slack.

When you must name something new, pick a short, understandable term of three words or fewer (STE 1.9).

    Bad:  Restart the asynchronous distributed configuration reconciliation subsystem component.
    Good: Restart the config reconciler.

Do not use regional, slang, or jargon words (STE 1.10). Words that only insiders know break the text for everyone else.

    Bad:  The firmware update bricked the router, so nuke the cache.
    Good: The firmware update made the router unusable, so delete the cache.

Use one term for one concept (STE 1.11). Never rotate synonyms for the same component. One component with three names reads as three components.

    Bad:  The endpoint validates the token. The route then checks quotas. Finally, the handler writes the audit log.
    Good: The handler validates the token. The handler then checks quotas. Finally, the handler writes the audit log.

Do not use verbs as nouns (STE 1.13).

    Bad:  Retry the job after the deploy completes.
    Good: Retry the job after the deployment completes.

Use American English spelling unless the project style guide says otherwise (STE 1.14). Never respell quoted text: if the API method is `initialise()`, keep it.

    Bad:  Initialise the colour of the dialogue box.
    Good: Initialize the color of the dialog box.

## 2. Multi-word nouns (STE 2.1-2.2)

Keep noun clusters to three words or fewer (STE 2.1). English stacks modifiers before the head noun, and the reader must untangle the whole stack. Break long clusters with prepositions ("of", "for", "in") or with a verb.

    Bad:  Fix the user session token cache invalidation logic.
    Good: Fix the logic that invalidates cached session tokens.

When a fixed name is longer than three words, write it in full the first time. Then introduce a short form or the official abbreviation, or hyphenate the word pairs that belong together (STE 2.2). Hyphenated groups count as one word (STE 8.7).

    Bad:  The Amazon Elastic Kubernetes Service node group autoscaling settings drift.
    Good: The autoscaling settings of the Amazon Elastic Kubernetes Service (EKS) node group drift.
          (From here on: "the EKS node group".)

    Bad:  Check the dead letter queue redrive policy config.
    Good: Check the redrive policy of the dead-letter queue.

Do not use hyphens to join more than three words into one group. A fully hyphenated five-word unit is as unreadable as the unhyphenated cluster.

## 3. Verbs (STE 3.1-3.7)

Use only simple verb forms: the infinitive, the imperative, the simple present, the simple past, the simple future, and the past participle as an adjective (STE 3.1, 3.2). Avoid the perfect and progressive tenses. Simple tenses also force you to state when things happened.

    Bad:  We have deprecated this flag, and it is being removed.
    Good: We deprecated this flag in v2.3. We will remove it in v3.0.

Use the past participle as an adjective to describe a state (STE 3.3). This is not passive voice.

    Bad:  Delete the records that have been orphaned by the migration.
    Good: Delete the orphaned records. The migration no longer references them.

Do not build auxiliary chains such as "is to be", "should have been", or "can be done by" (STE 3.4). Name the actor and use a simple form.

    Bad:  The cleanup job is to be run by the on-call engineer.
    Good: The on-call engineer runs the cleanup job.

Use "-ing" forms only inside fixed names and modifiers (STE 3.5). "Logging pipeline", "staging environment", and a "Troubleshooting" heading are fine. Progressive tenses and dangling participles are not.

    Bad:  Users hitting the endpoint while being throttled are seeing 429 errors.
    Good: When the rate limiter throttles a user, the endpoint returns a 429 error.

Write in the active voice (STE 3.6). In descriptive text, use the passive only when the agent is unknown. The active voice forces you to name the actor, which is exactly the information incident reports and reviews need.

    Bad:  The config file was overwritten during the release.
    Good: The release script overwrote the config file.

    Permitted passive (agent unknown):
    "Between 14:02 and 14:05, the row was deleted. The audit log shows no writer."

Use a verb for an action, not a nominalization (STE 3.7). Nominalizations hide the action and add filler verbs.

    Bad:  Perform the installation of the CLI before the execution of the tests.
    Good: Install the CLI before you run the tests.

## 4. Sentences (STE 4.1-4.5)

Write short, clear, concrete sentences (STE 4.1). Abstract statements give the reader nothing to act on. Replace them with the specific condition and the specific effect.

    Bad:  Different load levels will impact latency.
    Good: When load exceeds 500 requests per second, p99 latency rises above 2 seconds.

Do not drop words or use contractions to save space (STE 4.2). Telegram style saves the writer seconds and costs every reader more.

    Bad:  Config missing, service won't start.
    Good: The config file is missing. The service does not start.

Exception: commit subject lines follow Conventional Commits. Their terse, article-free style ("fix(home): stop create from swallowing stdin") is the convention there. The commit body follows the full rules.

Use a vertical list for complex content (STE 4.3). A sentence that chains four actions or four items is a list in disguise. End the intro line with a colon, and do not mix instructions and description in one list.

    Bad:  To test, check out the branch, run just build, apply the config with just
          switch --dry-run, and confirm that the diff shows no package delta.
    Good: To test:
          1. Check out the branch.
          2. Run `just build`.
          3. Run `just switch --dry-run`.
          4. Make sure that the diff shows no package delta.

Connect related sentences with connectors such as "and", "but", "then", "thus", and "as a result" (STE 4.4). Without the connector, the reader must infer the causal link.

    Bad:  The cache was cold. Latency spiked.
    Good: The cache was cold. As a result, latency spiked.

Write the articles ("the", "a", "an") and demonstrative adjectives ("this", "these") before nouns (STE 4.5). Dropped articles read fast to native speakers and ambiguous to everyone else.

    Bad:  Restart service after config change so scheduler picks up new limits.
    Good: Restart the service after a config change so that the scheduler picks up the new limits.

Skip the article before a noun with an identifier, because the pair is a proper noun: "Merge PR #482", "Restart pod api-6d9f".

## 5. Procedures: runbooks, how-tos, repro steps, test instructions (STE 5.1-5.5)

These rules apply to any text that tells the reader what to do: runbooks, how-to guides, bug reproduction steps, and the "how to test" section of a PR description.

Keep each sentence at 20 words or fewer (STE 5.1). Warnings and cautions must obey this limit too. Section 8 defines how to count.

    Bad:  Drain the node, wait until all pods have been rescheduled to other nodes
          and report Ready, and only then start the kernel upgrade.  (23 words)
    Good: Drain the node. Wait until all pods are Ready on other nodes. Then start
          the kernel upgrade.  (3 + 9 + 5 words)

Give one instruction per sentence (STE 5.2). Combine two actions only when they happen at the same time.

    Bad:  Scale the deployment to zero and delete the PVC and restart the operator.
    Good: 1. Scale the deployment to zero.
          2. Delete the PVC.
          3. Restart the operator.

    Simultaneous actions can share a sentence:
    "Run the load test and watch the error rate."

Write instructions in the imperative (STE 5.3). "Should be", "needs to be", and "can be" leave open who acts, whether the step is optional, and whether it already happened.

    Bad:  The cache should be cleared before each test run.
    Good: Clear the cache before each test run.

When a condition applies, put the condition first, then a comma, then the command (STE 5.4). The reader must know the condition before acting, not after.

    Bad:  Roll back the release if the error rate stays above 1% for 5 minutes.
    Good: If the error rate stays above 1% for 5 minutes, roll back the release.

Notes give information, never instructions (STE 5.5). A reader can skip every note and must still complete the procedure. Note sentences may have up to 25 words. Limits and expected results belong in the step itself, not in a note.

    Bad:  NOTE: Remember to disable the cron job before you start.
    Good: 1. Disable the cron job.
          ...
          NOTE: The first full sync takes about 10 minutes.

    Bad:  3. Run the benchmark.
          NOTE: The p99 must stay below 250 ms.
    Good: 3. Run the benchmark. The p99 must stay below 250 ms.

## 6. Description: READMEs, architecture docs, ticket context (STE 6.1-6.6)

These rules apply to text that explains how something works: READMEs, architecture and design docs, and the context section of a ticket. Descriptive text never uses the imperative.

Give information gradually, one subject per sentence (STE 6.1). A sentence that nests three facts makes the reader parse instead of read.

    Bad:  The exporter, which the sidecar configures at startup from env vars that
          ops maintain in the Helm values, pushes metrics to Prometheus with retries.
    Good: The exporter pushes metrics to Prometheus. The sidecar configures the
          exporter at startup from the env vars in the Helm values. The sidecar
          also retries failed pushes.

Repeat key words to chain sentences into a logical structure (STE 6.2). Each sentence should pick up a term from the one before. This is the paragraph-level twin of rule 1.11.

    Bad:  The scheduler assigns jobs to workers. Tasks are then pulled by executors
          from the queue.
    Good: The scheduler assigns jobs to workers. The workers pull their jobs from
          the queue.

Keep each sentence at 25 words or fewer (STE 6.3). Descriptive text gets 5 more words than procedural text because it carries more context.

    Bad:  The gateway is a reverse proxy that terminates TLS, authenticates requests,
          applies rate limits, rewrites paths and forwards traffic to upstream
          services based on routing rules defined in YAML.  (29 words)
    Good: The gateway is a reverse proxy that terminates TLS and authenticates
          requests. It applies rate limits, rewrites paths, and forwards traffic to
          upstream services. YAML files define the routing rules.

Start each paragraph with a topic sentence (STE 6.4). The reader who scans only the first sentence of each paragraph should get a correct outline of the document.

    Bad:  We looked at polling last sprint. Polling needed a cursor table and burned
          API quota. Webhooks avoid both. So the ingest service now uses webhooks.
    Good: The ingest service uses webhooks instead of polling. Polling needed a
          cursor table and burned API quota. Webhooks avoid both problems.

Give each paragraph exactly one topic (STE 6.5). A stray sentence about a second topic belongs in its own paragraph.

    Bad:  (one paragraph) The worker retries failed jobs with exponential backoff.
          Deployment happens through Argo CD. Retries stop after five attempts.
    Good: (paragraph 1) The worker retries failed jobs with exponential backoff.
          Retries stop after five attempts.
          (paragraph 2) Argo CD deploys the worker.

Keep paragraphs to six sentences or fewer (STE 6.6). When a paragraph grows past six sentences, it almost always hides a topic shift. Split there.

    Bad:  (one 7-sentence paragraph) The CLI reads its config from ~/.config/app.
          It merges flags over the config. Flags win. The config supports profiles.
          Profiles map to environments. The default profile is "dev". The
          APP_PROFILE variable overrides it.
    Good: (paragraph 1) The CLI reads its config from ~/.config/app. It merges
          flags over the config. Flags win.
          (paragraph 2) The config supports profiles. Profiles map to environments.
          The default profile is "dev". The APP_PROFILE variable overrides it.

## 7. Warnings: destructive commands, breaking changes, data loss (STE 7.1-7.3)

In IT texts, safety instructions guard destructive commands, breaking changes, and irreversible data operations. Adapt the STE risk levels: use WARNING for irreversible harm (data loss, security exposure, production outage) and CAUTION for recoverable damage or degradation. When both levels apply, use WARNING (STE 7.1).

Name the risk level explicitly (STE 7.1). A vague "be careful" carries no information about severity.

    Bad:  Note: be careful with this command.
    Good: WARNING: `terraform destroy` deletes the production database. The
          database has no backup.

Start the warning with a clear command or condition (STE 7.2). The reader must learn what to do, or not to do, in the first words.

    Bad:  Data loss occurs because the --force flag drops all tables when the
          migration runs against production.
    Good: WARNING: Do not run the migration with --force against production. The
          flag drops all tables.

Explain the consequence (STE 7.3). A reader who understands the risk complies. A bare prohibition invites experiments.

    Bad:  CAUTION: Do not edit the generated file.
    Good: CAUTION: Do not edit the generated file. The next build overwrites
          manual edits.

Place the warning before the instruction it protects. A warning after the step arrives after the damage.

    Bad:  1. Run the cleanup script.
             WARNING: The script deletes all local branches.
    Good: WARNING: The cleanup script deletes all local branches. Push unmerged
          work first.
          1. Run the cleanup script.

## 8. Punctuation and word count (STE 8.1-8.7)

Use standard English punctuation, but never the semicolon (STE 8.1). The semicolon invites long sentences and is easy to misuse. Write two sentences instead.

    Bad:  The token is short-lived; refresh it before each call.
    Good: The token is short-lived. Refresh it before each call.

Use hyphens to connect words that are directly related (STE 8.2). The hyphen shows the reader which words form one unit.

    Bad:  Use a read only long lived token for CI.
    Good: Use a read-only, long-lived token for CI.

Use parentheses for references, identifiers, abbreviations, short explanations, and alternatives (STE 8.3). Do not hide instructions in them.

    Bad:  Deploy the chart (remember to bump the version first).
    Good: Bump the chart version. Then deploy the chart (see the release runbook).

The word-count rules make the 20-word and 25-word limits mechanical:

A colon before a vertical list ends the sentence for counting (STE 8.4). The intro line must fit the limit on its own, and each list item counts as a new sentence with the same limit.

Text in parentheses counts as one word of the outer sentence, and its content counts separately as its own sentence (STE 8.5).

    Example: "Make sure that the DEBUG flag is off (the banner is hidden)."
    The outer sentence has 9 words. The text in parentheses is its own
    4-word sentence.

Count each of these as one word (STE 8.6): a number, a number with its unit, an abbreviation, an alphanumeric identifier, quoted text, a title or heading or label, and a proper noun of a person or organization. Code spans and file paths are quoted text.

    Example: "Set `spring.datasource.max-lifetime` to 30 s in `application.yaml`."
    6 words: three plain words, two identifiers, and one number with its unit.

Hyphenated groups count as one word (STE 8.7). "The user-facing error catalog" has 4 words.

## 9. Writing practices (STE 9.1-9.4, GR-1 to GR-8)

Rewrite the sentence when a word swap is not enough (STE 9.1). Replacing one fancy word with a plain one often leaves a broken sentence. Ask what the sentence must say, then say that.

    Bad:  The incidence of nulls in the payload is problematic.
    Poor: The presence of nulls in the payload is bad.  (word swap, still vague)
    Good: Null fields in the payload break the parser.

Use each word with its precise meaning (STE 9.2). Metaphorical or approximate wording forces the reader to guess magnitudes.

    Bad:  The latency went through the roof after the index rebuild.
    Good: The p99 latency increased from 80 ms to 4 s after the index rebuild.

Avoid phrasal verbs. Prefer the precise single verb (STE 9.3). Phrasal verbs carry idiomatic meanings that non-native readers and translators miss.

    Bad:  Bring up the cluster, carry out the smoke tests, and shut off alerting.
    Good: Start the cluster, run the smoke tests, and disable alerting.

Use a consistent style (STE 9.4). Repeat the same wording for the same kind of step. A reader treats every wording change as a meaning change.

    Bad:  1. Deploy the api service.
          2. Ship the worker.
          3. Roll out the cron jobs.
    Good: 1. Deploy the api service.
          2. Deploy the worker.
          3. Deploy the cron jobs.

### General recommendations

GR-1: Write the conjunction "that" after verbs such as "make sure", "verify", "check", and "show". It marks where the subordinate clause starts and helps translation.

    Bad:  Verify the flag is off and make sure the job completed.
    Good: Verify that the flag is off and make sure that the job completed.

GR-2: Watch the preposition "with". It can mean "that has", "together with", or "by means of". If the sentence allows two readings, split it. When "with" is clear, keep the primary action verb, not "use".

    Bad:  Restart the pods with the new config.
    Good: Apply the new config. Then restart the pods.

    Poor: Use curl to test the endpoint.
    Good: Test the endpoint with curl.

GR-3: Replace an ambiguous pronoun with the noun it stands for. If "it" or "they" can point at two nouns, name the noun.

    Bad:  If the workers reconnect to the brokers too fast, they crash.
    Good: If the workers reconnect to the brokers too fast, the brokers crash.

GR-4: Give "this" a noun. A bare "this" can point at the last noun, the last clause, or the whole paragraph. In review comments, the bare "this" is the single most common source of ambiguity. Always attach the noun.

    Bad:  This breaks retries.
    Good: This early return breaks retries.

GR-5: Watch false friends. A word that looks like one in your native language can mean something else in English. German "aktuell" means "current", not "actual".

    Bad:  The actual version is 2.3, so the handbook is obsolete.
    Good: The current version is 2.3, so the handbook is outdated.

GR-6: Avoid Latin abbreviations. Write "for example" instead of "e.g.", "that is" instead of "i.e.", and drop "etc." or name the rest.

    Bad:  Configure the sinks (e.g., S3, GCS, etc.) before ingest, i.e., before
          the first run.
    Good: Configure the sinks (for example, S3 or GCS) before the first run.

GR-7: Use inclusive language. Use the neutral IT terms: allowlist and blocklist, primary and replica, main branch. Do not use "he" or "she" for the reader or a role. Repeat the role noun or use "they".

    Bad:  Add the IP to the whitelist, then rebuild the master branch on the
          slave node.
    Good: Add the IP to the allowlist, then rebuild the main branch on the
          replica node.

GR-8: Use the possessive form ("the user's token") only when you are sure it is correct. When in doubt, use "of". Never attach a possessive to an identifier or a code span.

    Bad:  Check `app.yaml`'s keys against the pods' statuses's conditions field.
    Good: Check the keys in `app.yaml` against the conditions field in the status
          of each pod.
