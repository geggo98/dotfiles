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
  echo "Default sub-langs: '.*-orig' (regex: only original-language auto-caption"
  echo "tracks; translate locally instead of pulling YouTube's dubbed tracks,"
  echo "which quickly triggers HTTP 429 rate limits)."
  echo ""
  echo "Example overrides: +yt-dlp-transcript <url> de,en"
  echo "                   +yt-dlp-transcript <url> 'en.*'"
  echo ""
  echo "-q, --stdout   Pipe mode: transcripts to stdout, info lines"
  echo "               suppressed, errors on stderr only."
  return 1
end
set --local url $argv[1]
set --local langs '.*-orig'
if test (count $argv) -ge 2
  set langs $argv[2]
end
set --local tmproot /tmp
if test -n "$TMPDIR"
  set tmproot $TMPDIR
end
set --local outdir $tmproot/yt-dlp-transcript
mkdir -p $outdir

set --local marker (mktemp)

set --local quiet_args
if set --query _flag_stdout
  set quiet_args --quiet --no-warnings --no-progress
end

yt-dlp --ignore-config \
  --no-playlist \
  --skip-download \
  --write-subs \
  --write-auto-subs \
  --sub-langs "$langs" \
  --sub-format "vtt/best" \
  --convert-subs vtt \
  --sleep-subtitles 2 \
  $quiet_args \
  --output "$outdir/%(id)s.%(ext)s" \
  $url
or begin
  set --local rc $status
  rm -f $marker
  return $rc
end

for vtt in $outdir/*.vtt
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
    if not set --query _flag_stdout
      echo "VTT:        $vtt"
      echo "Transkript: $txt"
    end
  end
  if set --query _flag_stdout; and test $vtt -nt $marker
    cat $txt
  end
end

rm -f $marker
