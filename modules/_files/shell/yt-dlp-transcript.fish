argparse 'q/stdout' -- $argv
or return $status

if test (count $argv) -eq 0
  echo "Usage: +yt-dlp-transcript [-q|--stdout] <url> [sub-langs]"
  echo ""
  echo "Download subtitles (VTT) and write a cleaned plain-text"
  echo "transcript into \$TMPDIR/yt-dlp-transcript/<id>.<lang>.{vtt,txt}."
  echo ""
  echo "Uses --ignore-config so the global 'sub-langs = all' setting"
  echo "in ~/.config/yt-dlp/config does not force every language."
  echo ""
  echo "Without sub-langs the original-language track is detected"
  echo "automatically: YouTube's machine translations carry a 'tlang='"
  echo "parameter in their URL, the original does not. Uploader-provided"
  echo "subtitles win over auto-captions in the same language. Only that"
  echo "one track is fetched -- pulling YouTube's translated tracks"
  echo "quickly triggers HTTP 429 rate limits; translate locally instead."
  echo ""
  echo "Example overrides: +yt-dlp-transcript <url> de,en"
  echo "                   +yt-dlp-transcript <url> 'en.*'"
  echo ""
  echo "-q, --stdout   Pipe mode: transcripts to stdout, info lines"
  echo "               suppressed, errors on stderr only."
  return 1
end
set --local url $argv[1]
set --local langs ''
if test (count $argv) -ge 2
  set langs $argv[2]
end
set --local tmproot /tmp
if test -n "$TMPDIR"
  set tmproot $TMPDIR
end
set --local outdir $tmproot/yt-dlp-transcript
mkdir -p $outdir

set --local quiet_args
if set --query _flag_stdout
  set quiet_args --quiet --no-warnings --no-progress
end

# Probe once; the download below replays this JSON via --load-info-json, so the
# extractor (and its JS challenge) still runs only a single time.
set --local info (mktemp)
set --local probe_args --ignore-config --no-playlist --skip-download --write-auto-subs -J
if test -z "$langs"
  # Auto mode only: drops the manual-subs x translation-languages cross product
  # (3901 -> 157 entries on a multi-audio video). Left off for explicit langs so
  # translated tracks like 'en-de-DE' stay requestable.
  set --append probe_args --extractor-args "youtube:skip=translated_subs"
end
yt-dlp $probe_args $quiet_args $url >$info
or begin
  set --local rc $status
  rm -f $info
  return $rc
end

set --local id (jq -r '.id // empty' <$info)

if test -z "$langs"
  set langs (jq -r '
    def orig_auto:
      (.automatic_captions // {}) | to_entries
      | map(select(.value | any(.url | test("[?&]tlang=")) | not)) | map(.key);
    orig_auto as $o
    | ((.subtitles // {}) | keys) as $m
    | (($o | map(select(endswith("-orig"))) | first) // ($o | first)) as $L
    | if $L != null then
        ($L | sub("-orig$"; "")) as $b
        | if ($m | index($b)) then [$b]
          elif ($m | map(select(startswith($b + "-"))) | length) > 0
            then [($m | map(select(startswith($b + "-"))) | first)]
          else [$L] end
      elif ($m | length) > 0 then $m
      else [] end
    | join(",")' <$info)

  set --local picked (string split --no-empty ',' -- $langs)
  if test (count $picked) -eq 0
    echo "+yt-dlp-transcript: no subtitle tracks available for $url" >&2
    rm -f $info
    return 1
  end
  # No original-language signal and a pile of uploader tracks: guessing would
  # fetch all of them and invite a 429. Make the user choose instead.
  if test (count $picked) -gt 4
    echo "+yt-dlp-transcript: cannot tell which of these tracks is the original:" >&2
    echo "  $langs" >&2
    echo "Pick one: +yt-dlp-transcript $url <lang>" >&2
    rm -f $info
    return 1
  end
end

yt-dlp --ignore-config \
  --load-info-json $info \
  --skip-download \
  --write-subs \
  --write-auto-subs \
  --sub-langs "$langs" \
  --sub-format "vtt/best" \
  --convert-subs vtt \
  --sleep-subtitles 2 \
  $quiet_args \
  --output "$outdir/%(id)s.%(ext)s"
or begin
  set --local rc $status
  rm -f $info
  return $rc
end

rm -f $info

# Scoped to this video's id: $outdir is shared, and an unscoped glob would
# report stale tracks from every previously transcribed video.
for vtt in $outdir/$id.*.vtt
  set --local txt (string replace -r '\.vtt$' '.txt' $vtt)
  if not test -e $txt; or test $vtt -nt $txt
    sed -E \
      -e '/^WEBVTT/d' \
      -e '/^Kind:/d' \
      -e '/^Language:/d' \
      -e '/^NOTE/d' \
      -e '/^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} --> /d' \
      -e 's/<[^>]+>//g' \
      -e '/^[[:space:]]*$/d' \
      $vtt | awk '!seen[$0]++' > $txt
  end
  if set --query _flag_stdout
    cat $txt
  else
    echo "VTT:        $vtt"
    echo "Transkript: $txt"
  end
end
