# Read binary audio bytes from stdin, transcribe them with voxscriber, and print
# the Markdown transcript to stdout (and nothing else), forwarding extra flags:
#
#   curl -sL URL | +transcribe-pipe | +wait-and-exec claude -p 'Please summarize'
#
# Pipe the result through +wait-and-exec: transcription takes minutes (model load
# + inference produce no output until the very end), and `claude -p` abandons
# stdin after a short grace period — +wait-and-exec holds the pipe open until the
# first transcript byte arrives. A bare `… | claude -p …` often races and loses.
#
# voxscriber takes a positional audio file PATH (it cannot read stdin) and never
# writes Markdown to stdout, so we stage stdin to a real seekable file, transcribe
# into a throwaway dir, then cat the generated .md. We deliberately do NOT use
# fish's `psub` here: `voxscriber (psub …)` needs the command substitution to read
# this function's piped stdin, but fish command substitutions do not inherit the
# surrounding job's stdin and hang (verified on fish 4.7.1). Reading stdin
# directly in the body is robust.

# Refuse a non-piped / interactive stdin early — there are no bytes to read.
if isatty stdin
  echo "+transcribe-pipe: reads audio from stdin, e.g.  curl -sL URL | +transcribe-pipe | +wait-and-exec claude -p 'summarize'" >&2
  return 2
end

# Throwaway dir for the staged audio + generated transcript (keeps $PWD clean;
# voxscriber always writes its output files into --output).
set --local d (mktemp -d)

# Unique filename stem. voxscriber keys its 16 kHz conversion cache on the input's
# Python Path.stem ("{stem}_16khz_mono.wav" under $TMPDIR/diarization_cache), so a
# constant stem would make a second piped clip silently reuse the first clip's
# cached audio. The random token sits before the trailing extension so it lands in
# the stem. The .wav label is cosmetic — ffprobe/ffmpeg/PyAV sniff the container by
# content, never by suffix — so any real audio format still decodes.
set --local rnd (random)
set --local audio "$d/clip.$fish_pid.$rnd.wav"

# Buffer ALL of stdin to the real on-disk (seekable) file before transcoding.
# voxscriber opens/seeks the input several times (ffprobe, then a separate
# ffmpeg -i), which a FIFO could not satisfy. Large inputs are bounded by disk.
command cat > $audio

# Empty input (e.g. a curl of a 404) — fail fast instead of handing voxscriber a
# 0-byte file.
if not test -s $audio
  echo "+transcribe-pipe: empty input on stdin — nothing to transcribe" >&2
  command rm -rf $d
  return 2
end

# --quiet:      voxscriber prints its [VoxScriber] progress to STDOUT, which would
#               corrupt the Markdown going to `claude -p`; --quiet silences it
#               (model-download/tqdm progress stays on stderr regardless).
# --formats md: select the Markdown writer (the flag is plural; --format does not
#               exist). NOT --print: that renders an ==== banner + ANSI-coloured
#               timestamped text via Rich, not raw Markdown.
# --output $d:  keep generated files in the throwaway dir, not $PWD.
# $argv LAST:   any user flag (--model, --speakers, --language, --hf-token, …)
#               overrides our defaults; the positional comes first so it is never
#               swallowed as a flag value. Do not pass --output or a second file.
# >&2: belt-and-braces — send voxscriber's own stdout to stderr so the ONLY thing
#      on our stdout is the `cat` of the .md below. --quiet already silences the
#      [VoxScriber] progress, but this also covers batch progress, a user-supplied
#      --print, or any other stray stdout, keeping the pipe to `claude -p` clean.
voxscriber $audio --quiet --formats md --output $d $argv >&2
set --local rc $status

# Emit clean Markdown on stdout. Collect the glob into a variable first: a bare
# `cat $d/*.md` raises fish's "No matches for wildcard" hard error when voxscriber
# produced nothing (e.g. on failure); a `set` assignment is empty-safe.
set --local mds $d/*.md
if test $rc -eq 0; and test (count $mds) -gt 0
  cat $mds
end

# Tidy up: the throwaway dir, plus this run's per-stem conversion-cache entries
# (best effort; the cache dir lives under $TMPDIR, which the OS reaps anyway).
command rm -rf $d
set --local stale "$TMPDIR"/diarization_cache/clip.$fish_pid.$rnd*
test (count $stale) -gt 0; and command rm -f $stale

return $rc
