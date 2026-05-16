argparse --stop-nonopt 't/timeout=' 'e/wait-eof' -- $argv
or return $status

if test (count $argv) -eq 0
  echo "Usage: +wait-and-exec [--timeout SECONDS] [--wait-eof] <command> [args...]"
  echo ""
  echo "Wait until stdin has data, then exec <command> with stdin passed through."
  echo "Useful when <command> (e.g. 'claude -p') gives up on stdin after a short"
  echo "grace period and the upstream producer takes longer to deliver the first"
  echo "byte (e.g. 'yt-dlp' downloading subtitles)."
  echo ""
  echo "  -t, --timeout SECONDS  Wait at most SECONDS for the first byte. If no"
  echo "                         data arrives in time, exit 124 (gtimeout-style)"
  echo "                         and do NOT start <command>."
  echo "  -e, --wait-eof         Buffer all of stdin via 'sponge' and release it"
  echo "                         atomically on EOF. Combine with --timeout to cap"
  echo "                         the wait; on timeout sponge is killed and any"
  echo "                         buffered data is lost (<command> sees empty stdin)."
  echo ""
  echo "Examples:"
  echo "  +yt-dlp-transcript -q URL | +wait-and-exec claude -p 'Summarize'"
  echo "  slow-source | +wait-and-exec --timeout 60 grep -i error"
  echo "  multi-line-gen | +wait-and-exec --wait-eof jq ."
  return 1
end

if set --query _flag_wait_eof
  if set --query _flag_timeout
    gtimeout $_flag_timeout sponge | command $argv
  else
    sponge | command $argv
  end
else
  set --local t "-"
  if set --query _flag_timeout
    set t $_flag_timeout
  end
  perl -e '
    vec(my $r = "", fileno(STDIN), 1) = 1;
    my $t = shift @ARGV;
    if ($t eq "-") {
      select($r, undef, undef, undef);
    } else {
      my $n = select($r, undef, undef, $t + 0);
      exit 124 if $n == 0;
    }
    exec { $ARGV[0] } @ARGV
      or die "+wait-and-exec: exec $ARGV[0] failed: $!\n";
  ' -- $t $argv
end
