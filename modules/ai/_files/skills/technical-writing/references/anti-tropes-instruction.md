# Writing Patterns to Avoid

Any of these patterns used once might be fine. The problem is when multiple appear together or when a single one repeats. Write with varied, specific, human prose.

---

## Word Choice

### "Quietly" and Other Magic Adverbs

Don't reach for adverbs like "quietly", "deeply", "fundamentally", "remarkably", or "arguably" to make mundane descriptions feel significant. If something is important, show it — don't signal it with an adverb.

**Avoid:**
- "quietly orchestrating workflows, decisions, and interactions"
- "the one that quietly suffocates everything else"
- "a quiet intelligence behind it"

The same applies to an adverb that props up a weak verb. Use a stronger verb or the measured value.

**Avoid → write:**
- "runs quickly" → "is fast", or "finishes in 80 ms"
- "significantly improves" → "cuts p99 latency from 4 s to 0.8 s"

### "Delve" and Overused Vocabulary

Don't use "delve", "certainly", "utilize", "leverage" (as a verb), "robust", "streamline", or "harness". Prefer plain, specific alternatives.

**Avoid:**
- "Let's delve into the details..."
- "Delving deeper into this topic..."
- "We certainly need to leverage these robust frameworks..."

### "Tapestry", "Landscape", and Ornate Nouns

Don't reach for grandiose nouns where simpler ones work. Avoid "tapestry", "landscape", "paradigm", "synergy", "ecosystem" (when used loosely), and "framework" as vague filler.

**Avoid:**
- "The rich tapestry of human experience..."
- "Navigating the complex landscape of modern AI..."
- "The ever-evolving landscape of technology..."

### Abstract Metaphor Nouns

Technical-sounding nouns and verbs that name no mechanism. Each usually has a plainer, concrete replacement. Pick the concrete word, or say what the thing actually does.

**Avoid → write:**
- "substrate", "bedrock", "scaffolding" → "base", "foundation", or the named component
- "vector" (for a route or method) → "way", "method", "path"
- "surface" ("the API surface") → "the public functions", "the endpoints"
- "primitive" as a noun, "modality", "paradigm", "locus", "nexus", "vantage" → the specific thing, or "kind", "mode", "approach"
- "wedge", "wedge in" → "add"
- "harness" as a metaphor → "use", or the tool's name
- "gold-plating" → "more than the job needs"
- "ratchet" as a metaphor → the mechanism's real name, or "a limit that only tightens"
- "evacuate" (for code) → "move out"
- "endgame" → "the last phase"
- "north star", "flywheel" → the goal, or the feedback loop in plain words

A named pattern is fine when the text says what it means the first time it appears. The test: could a developer say the word out loud in a code review without sounding like a slide deck?

### The "Serves As" Dodge

Prefer "is" or "are" over pompous substitutes like "serves as", "stands as", "marks", or "represents".

**Avoid:**
- "The building serves as a reminder of the city's heritage."
- "Gallery 825 serves as LAAA's exhibition space for contemporary art."
- "The station marks a pivotal moment in the evolution of regional transit."

---

## Sentence Structure

### Negative Parallelism

Don't frame points as "It's not X — it's Y." This creates false profundity. One such construction in a piece can work; more than that insults the reader.

**Avoid:**
- "It's not bold. It's backwards."
- "Feeding isn't nutrition. It's dialysis."
- "Half the bugs you chase aren't in your code. They're in your head."

### "Not X. Not Y. Just Z."

Don't build fake tension by negating two things before landing a point.

**Avoid:**
- "Not a bug. Not a feature. A fundamental design flaw."
- "Not ten. Not fifty. Five hundred and twenty-three lint violations across 67 files."
- "not recklessly, not completely, but enough"

### "The X? A Y."

Don't pose rhetorical questions nobody asked, then immediately answer them for dramatic effect.

**Avoid:**
- "The result? Devastating."
- "The worst part? Nobody saw it coming."
- "The scary part? This attack vector is perfect for developers."

### Anaphora Abuse

Don't repeat the same sentence opening multiple times in quick succession.

**Avoid:**
- "They assume that users will pay... They assume that developers will build... They assume that ecosystems will emerge..."
- "They could expose... They could offer... They could provide... They could create..."
- "They have built engines, but not vehicles. They have built power, but not leverage. They have built walls, but not doors."

### Tricolon Abuse

One rule-of-three is elegant. Don't stack multiple tricolons back-to-back.

**Avoid:**
- "Products impress people; platforms empower them. Products solve problems; platforms create worlds. Products scale linearly; platforms scale exponentially."
- "identity, payments, compute, distribution"
- "workflows, decisions, and interactions"

### "It's Worth Noting"

Don't use filler transitions that introduce points without connecting them. Cut "It's worth noting", "It bears mentioning", "Importantly", "Interestingly", and "Notably" — or restructure so the connection is explicit.

**Avoid:**
- "It's worth noting that this approach has limitations."
- "Importantly, we must consider the broader implications."
- "Interestingly, this pattern repeats across industries."

### Superficial Analyses

Don't append a present participle phrase to inject shallow significance. If an observation needs "highlighting its importance" tacked on, rewrite the observation so it speaks for itself.

**Avoid:**
- "contributing to the region's rich cultural heritage"
- "This etymology highlights the enduring legacy of the community's resistance and the transformative power of unity in shaping its identity."
- "underscoring its role as a dynamic hub of activity and culture"

### False Ranges

Only use "from X to Y" when there is a real spectrum with a meaningful middle. Don't use it to dress up a list of two loosely related things.

**Avoid:**
- "From innovation to implementation to cultural transformation."
- "From the singularity of the Big Bang to the grand cosmic web."
- "From problem-solving and tool-making to scientific discovery, artistic expression, and technological innovation."

### Gerund Fragment Litany

Don't follow a claim with a stream of verbless gerund fragments — standalone sentences with no grammatical subject. If you've made the point, move on.

**Avoid:**
- "Fixing small bugs. Writing straightforward features. Implementing well-defined tickets."
- "Reviewing pull requests. Debugging edge cases. Attending architecture meetings."
- "Shipping faster. Moving quicker. Delivering more."

---

## Paragraph Structure

### Short Punchy Fragments

Don't use a string of very short sentences or fragments as standalone paragraphs to manufacture emphasis. This is an inhuman writing style — use it sparingly and deliberately, not as a default cadence.

**Avoid:**
- "He published this. Openly. In a book. As a priest."
- "These weren't just products. And the software side matched. Then it professionalised. But I adapted."
- "Platforms do."

### Listicle in a Trench Coat

If you're writing a list, write a list. Don't disguise it as prose by wrapping each item in a paragraph beginning "The first...", "The second...", "The third...".

**Avoid:**
- "The first wall is the absence of a free, scoped API... The second wall is the lack of delegated access... The third wall is the absence of scoped permissions..."
- "The second takeaway is that... The third takeaway is that... The fourth takeaway is that..."

---

## Tone

### "Here's the Kicker"

Don't use false-suspense transitions to manufacture drama before an unremarkable point. Cut "Here's the kicker", "Here's the thing", "Here's where it gets interesting", and "Here's what most people miss".

**Avoid:**
- "Here's the kicker."
- "Here's the thing about AI adoption."
- "Here's where it gets interesting."

### "Think of It As..."

Don't assume the reader needs a metaphor to understand. Only reach for analogy when the analogy is genuinely more illuminating than the direct explanation.

**Avoid:**
- "Think of it like a highway system for data."
- "Think of it as a Swiss Army knife for your workflow."
- "It's like asking someone to buy a car they're only allowed to sit in while it's parked."

### "Imagine a World Where..."

Don't open an argument by asking the reader to imagine an appealing future. Make the argument directly.

**Avoid:**
- "Imagine a world where every tool you use -- your calendar, your inbox, your documents -- has a quiet intelligence behind it..."
- "In that world, workflows stop being collections of manual steps and start becoming orchestrations."

### False Vulnerability

Don't perform self-awareness. Simulated candor — pretending to break the fourth wall or admit a bias — reads as hollow. Real honesty is specific and has stakes; don't fake it.

**Avoid:**
- "And yes, I'm openly in love with the platform model"
- "And yes, since we're being honest: I'm looking at you, OpenAI, Google, Anthropic, Meta"
- "This is not a rant; it's a diagnosis"

### "The Truth Is Simple"

Don't assert that a point is obvious, clear, or simple — prove it. Telling the reader your point is clear is a signal it isn't.

**Avoid:**
- "The reality is simpler and less flattering"
- "History is unambiguous on this point"
- "History is clear, the metrics are clear, the examples are clear"

### Grandiose Stakes Inflation

Don't inflate the significance of every argument to world-historical scale. Match the stakes of your claims to what you're actually demonstrating.

**Avoid:**
- "This will fundamentally reshape how we think about everything."
- "will define the next era of computing"
- "something entirely new"

### "Let's Break This Down"

Don't adopt a teacher-student tone with a reader who hasn't asked for it. Cut "Let's break this down", "Let's unpack this", "Let's explore", and "Let's dive in".

**Avoid:**
- "Let's break this down step by step."
- "Let's unpack what this really means."
- "Let's explore this idea further."

### Vague Attributions

Don't cite unnamed authorities. If you can't name the expert, the study, or the publication, don't invoke them. Don't inflate one source into "several publications" or one person's view into a widely held consensus.

**Avoid:**
- "Experts argue that this approach has significant drawbacks."
- "Industry reports suggest that adoption is accelerating."
- "Observers have cited the initiative as a turning point."

### Invented Concept Labels

Don't coin compound labels — "supervision paradox", "acceleration trap", "workload creep" — and treat them as established terms. Name things precisely, or make the argument without the label.

**Avoid:**
- "the supervision paradox"
- "the acceleration trap"
- "workload creep"

### The Portable Sentence

Don't name a feeling where a mechanism or a number belongs. A sentence that could appear unchanged in the documentation of a different project says nothing about this one. Ask what the sentence tells the reader to do or know, and write that. If it cannot be restated as an instruction, a fact, or a number, cut it.

**Avoid → write:**
- "SQL you can read" → "`.toSQL()` returns the exact string sent to the database."
- "Types that follow your schema" → "Renaming a column fails the build."
- "Built for speed and reliability" → the benchmark result, or cut it.

---

## Formatting

### Em-Dash Overuse

Use em dashes sparingly — two or three per piece at most. Don't use them as a default mechanism for asides and pivots.

**Avoid:**
- "The problem -- and this is the part nobody talks about -- is systemic."
- "The tinkerer spirit didn't die of natural causes -- it was bought out."
- "Not recklessly, not completely -- but enough -- enough to matter."

### Bold-First Bullets

Don't begin every bullet with a bolded phrase. If you need bullets, let the content carry the list — not typographic decoration.

**Avoid:**
- "**Security**: Environment-based configuration with..."
- "**Performance**: Lazy loading of expensive resources..."

### Unicode Decoration

Don't use unicode arrows (→), curly quotes, or other characters that require special input. Use plain text equivalents (->), straight quotes, and standard punctuation.

**Avoid:**
- "Input → Processing → Output"
- "This leads to better outcomes → which means higher engagement"

---

## Composition

### Fractal Summaries

Don't summarize every section before and after writing it. Don't restate at the document level what you just said at the section level.

**Avoid:**
- "In this section, we'll explore... [3000 words later] ...as we've seen in this section."
- A conclusion that restates every point already made
- "And so we return to where we began."

### The Dead Metaphor

Introduce a metaphor, use it, then move on. Don't return to the same metaphor throughout an entire piece.

**Avoid:**
- "The ecosystem needs ecosystems to build ecosystem value."
- Walls and doors used 30+ times in the same article
- Every paragraph finding a way to reuse the same term

### Historical Analogy Stacking

Don't rapid-fire a list of historical companies or tech revolutions to build authority. One well-chosen analogy is stronger than five weak ones.

**Avoid:**
- "Apple didn't build Uber. Facebook didn't build Spotify. Stripe didn't build Shopify. AWS didn't build Airbnb."
- "Every major technological shift -- the web, mobile, social, cloud -- followed the same pattern."
- "Take Spotify... Or consider Uber... Airbnb followed a similar path... Shopify is another example... Even Discord..."

### One-Point Dilution

Don't restate a single argument in ten different ways across thousands of words. If you've made the point, move forward or stop.

**Avoid:**
- The same point restated eight ways across 4000 words
- Each section rephrasing the thesis with a different metaphor but adding nothing new

### Content Duplication

Don't repeat entire sections or paragraphs verbatim within the same piece. Read back what you've written before continuing.

**Avoid:**
- The same section appearing twice, word-for-word identical
- Paragraph 3 and paragraph 17 being the same sentence reworded

### The Signposted Conclusion

Don't announce the conclusion. End the piece — don't label the ending. Cut "In conclusion", "To sum up", and "In summary".

**Avoid:**
- "In conclusion, the future of AI depends on..."
- "To sum up, we've explored three key themes..."
- "In summary, the evidence suggests..."

### "Despite Its Challenges..."

Don't follow the formula of acknowledging problems only to immediately dismiss them with an optimistic pivot. If there are real challenges, engage with them.

**Avoid:**
- "Despite these challenges, the initiative continues to thrive."
- "Despite its industrial and residential prosperity, Korattur faces challenges typical of urban areas."

### Over-Compression

Don't write so tersely that the reader must decode. Dropped articles, verbless fragments, arrows and symbols in place of verbs, and unexplained abbreviations save the writer a few words and cost the reader the meaning. Write whole sentences. See `reader-comprehension.en.md` §7 for the measured background.

**Avoid → write:**
- "Parser rejects bad date → exit 2, no write" → "The parser rejects a bad date, exits with code 2, and writes nothing."
- "Cfg missing, svc no start." → "The config file is missing, so the service does not start."

This is the opposite failure to filler. Cutting a phrase that adds nothing is right. Cutting structure (an article, a `that`, a verb) is not.

---

## Punctuation

### Colon as a Mid-Sentence Connector

A colon is fine before a list or an example. Don't use it to join two clauses as a rhetorical hinge. The point reads better without the crutch.

**Avoid:**
- "If you're coming from traditional automation: instead of registering event handlers, you describe conditions."

**Write:**
- "Describing when the scheduler should fire works best as plain English."

A colon that introduces the reason or result of the preceding clause is still acceptable, as in "The job failed three times for the same reason: the timeout was too low." Check that the sentence would not be clearer as two.
- "Despite their promising applications, pyroelectric materials face several challenges that must be addressed for broader adoption."