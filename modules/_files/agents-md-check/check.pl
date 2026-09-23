#!/usr/bin/env perl
# Enforces the AGENTS.md size budget and checks that every `docs/*.md`
# pointer it names actually exists. See modules/agents-md-check.nix for why:
# Codex's project_doc_max_bytes truncates AGENTS.md silently past MAX_BYTES,
# and a dangling docs/ pointer is a dead end for a reader who follows it.
#
# Usage: check.pl <path-to-AGENTS.md> <max-bytes>
# Run from a directory that also holds docs/ (the caller `cp -r`s it there).
use strict;
use warnings;

my ($agents_md, $max_bytes) = @ARGV;
die "usage: check.pl <AGENTS.md> <max-bytes>\n" unless defined $agents_md && defined $max_bytes;

open my $fh, '<:raw', $agents_md or die "open $agents_md: $!\n";
local $/;
my $content = <$fh>;
close $fh;

my $size = length $content;
if ($size > $max_bytes) {
    die "AGENTS.md is $size bytes, over Codex's project_doc_max_bytes budget "
      . "of $max_bytes.\n"
      . "Codex silently truncates anything past that many bytes -- measured via\n"
      . "'project doc exceeds remaining budget; truncating' in\n"
      . "~/.codex/logs_2.sqlite before this file was split up. Move the detail\n"
      . "out to docs/<topic>.md (verbatim) and leave a short pointer here instead.\n";
}
print "AGENTS.md: $size / $max_bytes bytes OK\n";

# Every `docs/*.md` path AGENTS.md points a reader at must exist, so a
# pointer can never go stale silently.
my %seen;
my @missing;
# matches:     Full detail: `docs/nix-cache.md`.   ->  $1 eq "docs/nix-cache.md"
while ($content =~ m{`(docs/[a-zA-Z0-9_.-]+\.md)`}g) {
    my $ref = $1;
    next if $seen{$ref}++;
    push @missing, $ref unless -f $ref;
}
if (@missing) {
    die "AGENTS.md references docs/ files that do not exist: @missing\n";
}
printf "All %d distinct docs/*.md references in AGENTS.md resolve.\n", scalar keys %seen;
