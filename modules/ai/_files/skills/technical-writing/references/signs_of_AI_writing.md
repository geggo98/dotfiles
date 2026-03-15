# Signs of AI Writing

Source: Wikipedia's "Signs of AI writing" field guide.
Observations of writing and formatting conventions typical of AI chatbots.
This list is descriptive, not prescriptive.

## Content patterns

### Undue emphasis on significance, legacy, and broader trends

Words to watch: *stands/serves as*, *is a testament/reminder*,
*a vital/significant/crucial/pivotal/key role/moment*,
*underscores/highlights its importance/significance*, *reflects broader*,
*symbolizing its ongoing/enduring/lasting*, *contributing to the*,
*setting the stage for*, *marking/shaping the*, *represents/marks a shift*,
*key turning point*, *evolving landscape*, *focal point*,
*indelible mark*, *deeply rooted*

LLM writing puffs up importance by adding statements
about how arbitrary aspects represent or contribute to a broader topic.
LLMs include these statements for even the most mundane subjects.
Sometimes they add hedging preambles acknowledging
that the subject is relatively unimportant,
before talking about its importance anyway.

Examples:

> The Statistical Institute of Catalonia was officially established in 1989,
> **marking a pivotal moment** in the evolution of regional statistics.
> The founding **represented a significant shift** toward regional independence.
> This initiative **was part of a broader movement** to decentralize.

> **Though it saw only limited application**, it **contributes to the broader
> history** of early aviation engineering and **reflects the influence of
> French rotary designs** on German manufacturers.

### Undue emphasis on notability and media coverage

Words to watch: *independent coverage*,
*local/regional/national media outlets*, *profiled in*,
*written by a leading expert*, *active social media presence*

LLMs act as if the best way to prove notability
is to hit readers over the head with claims of notability,
often by listing sources without additional context.
They frequently note that subjects "maintain an active social media presence."

### Superficial analyses

Words to watch: *highlighting/underscoring/emphasizing ...*,
*ensuring ...*, *reflecting/symbolizing ...*,
*contributing to ...*, *cultivating/fostering ...*,
*encompassing ...*, *valuable insights*, *align/resonate with*

AI chatbots insert superficial analysis,
often by attaching a present participle ("-ing") phrase at the end of sentences.

> As of the April 2008 census, the population stood at approximately 56,998
> inhabitants, **creating a lively community within its borders.**
> Situated in the central-north region, Douera enjoys proximity to Algiers,
> **further enhancing its significance as a dynamic hub of activity and culture.**

### Promotional and advertisement-like language

Words to watch: *boasts a*, *vibrant*, *rich*, *profound*,
*enhancing*, *showcasing*, *exemplifies*, *commitment to*,
*natural beauty*, *nestled*, *in the heart of*, *groundbreaking*,
*renowned*, *featuring*, *diverse array*

LLMs have serious problems keeping a neutral tone.
Even when prompted to use an encyclopedic tone,
output tends toward advertisement-like writing or travel-guide prose.
They often insert promotional language while claiming they removed it.

### Vague attributions and overgeneralization

Words to watch: *Industry reports*, *Observers have cited*,
*Experts argue*, *Some critics argue*,
*several sources/publications* (when only few are cited)

AI chatbots attribute opinions to vague authorities (weasel wording)
and exaggerate the quantity of sources.
They may present one or two sources as widely held views.

### Outline-like conclusions about challenges and future prospects

Words to watch: *Despite its... faces several challenges...*,
*Despite these challenges*, *Future Outlook*

Many LLM-generated articles include a "Challenges" section
beginning with "Despite its [positive words], [subject] faces challenges..."
ending with vague optimism or speculation.

## Language and grammar

### High density of "AI vocabulary" words

Words to watch: *Additionally* (especially beginning a sentence),
*align with*, *boasts*, *bolstered*, *crucial*, *delve*,
*emphasizing*, *enduring*, *enhance*, *fostering*, *garner*,
*highlight* (verb), *interplay*, *intricate/intricacies*,
*key* (adjective), *landscape* (abstract noun),
*meticulous/meticulously*, *pivotal*, *showcase*,
*tapestry* (abstract noun), *testament*,
*underscore* (verb), *valuable*, *vibrant*

These words co-occur in LLM output.
One or two may be coincidental,
but an edit introducing many of them is one of the strongest tells.

Distribution by era:

- **2023 to mid-2024** (GPT-4): *Additionally*, *boasts*, *bolstered*,
  *crucial*, *delve*, *emphasizing*, *enduring*, *garner*,
  *intricate/intricacies*, *interplay*, *key*, *landscape*,
  *meticulous/meticulously*, *pivotal*, *underscore*,
  *tapestry*, *testament*, *valuable*, *vibrant*
- **Mid-2024 to mid-2025** (GPT-4o): *align with*, *bolstered*,
  *crucial*, *emphasizing*, *enhance*, *enduring*, *fostering*,
  *highlighting*, *pivotal*, *showcasing*, *underscore*, *vibrant*
- **Mid-2025 and on** (GPT-5): *emphasizing*, *enhance*,
  *highlighting*, *showcasing*

### Avoidance of basic copulatives ("is"/"are")

Words to watch: *serves as/stands as/marks/represents [a]*,
*boasts/features/offers [a]*

LLM-generated text substitutes *serves as a* or *marks the*
for simpler forms with *is* or *are*.
Prefers *features*, *offers* over *has*.

### Negative parallelisms

LLMs use "not X, but Y" and "not just X, but also Y"
constructions to appear balanced and thoughtful.
Creates false profundity when overused.

### Rule of three

LLMs overuse the rule of three:
"adjective, adjective, adjective"
or "short phrase, short phrase, and short phrase."
Often used to make superficial analyses appear comprehensive.

### Elegant variation

LLMs avoid repeating words due to repetition-penalty code.
A character's name becomes "protagonist," "key player,"
"eponymous character" in successive mentions.

## Style

### Title case in headings

AI chatbots capitalize all main words in section headings.

### Overuse of boldface

AI chatbots emphasize every instance of a chosen word or phrase
in a mechanical, "key takeaways" fashion.

### Inline-header vertical lists

Vertical lists where bullet marker is followed by
an inline boldfaced header separated by a colon from descriptive text.

### Overuse of em dashes

LLM output uses em dashes more often than human-written text
and in places where humans use commas, parentheses, or colons.
Often in formulaic, "punched up" sales-like writing.

### Curly quotation marks and apostrophes

ChatGPT and DeepSeek use curly quotation marks.
Gemini and Claude typically do not.

## Communication artifacts

### Collaborative communication

Words to watch: *I hope this helps*, *Of course!*,
*Certainly!*, *Would you like...*, *is there anything else*,
*let me know*, *here is a*

Editors paste text meant as correspondence rather than article content.

### Knowledge-cutoff disclaimers

Words to watch: *as of [date]*, *Up to my last training update*,
*While specific details are limited/scarce...*,
*not widely available/documented/disclosed*

### Phrasal templates and placeholder text

AI generates fill-in-the-blank templates
that users forget to complete before pasting.

## Markup artifacts

### Use of Markdown in non-Markdown contexts

Markdown syntax (asterisks for bold, hash for headings)
mixed into contexts expecting different markup.

### Reference markup bugs

ChatGPT may add `contentReference[oaicite:0]{index=0}`,
`oai_citation`, `citeturn0search0`, or similar artifacts.

### UTM source parameters

ChatGPT adds `utm_source=openai` or `utm_source=chatgpt.com` to URLs.
Microsoft Copilot adds `utm_source=copilot.com`.
Grok uses `referrer=grok.com`.

## Citation problems

### Broken external links

Multiple citations with broken external links (404 errors)
in a new article is a strong sign of AI generation,
especially if the dead links are not found in web archives.

### Invalid DOIs and ISBNs

Unresolvable DOIs and invalid ISBN checksums
indicate hallucinated references.

### Book citations without page numbers

LLMs generate book citations without page numbers.
Some include page numbers, but the cited pages
do not verify the text.

## Historical indicators (less common in newer models)

### Didactic disclaimers (2022-2024)

Words to watch: *it's important/critical/crucial to note/remember/consider*,
*worth noting*, *may vary*

Older LLMs added disclaimers about topics being "important to note."

### Section summaries

Words to watch: *In summary*, *In conclusion*, *Overall*

Older LLMs added "Conclusion" sections
and ended paragraphs by restating core ideas.

### Prompt refusal

Words to watch: *as an AI language model*,
*I cannot offer medical advice, but I can...*

Outright refusals have become increasingly rare in newer models.

## Ineffective indicators (do not rely on these)

- Perfect grammar (many editors are skilled writers)
- Mixed formal and casual registers (may indicate code switching)
- "Bland" or "robotic" prose (LLMs have specific traits, not generic blandness)
- "Fancy" or "academic" prose (correlation is with specific words, not formality)
- Unsourced content (predates LLMs; modern LLMs do cite sources)
- Transition words in isolation (only a few are specifically overused by AI)
