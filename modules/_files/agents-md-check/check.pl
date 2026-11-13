#!/usr/bin/env perl
# Keeps the agent documentation honest. See modules/agents-md-check.nix for why.
#
#   1. AGENTS.md stays under the byte budget.
#   2. Every `docs/*.md` path that AGENTS.md names exists.
#   3. Every docs/*.md file is named in AGENTS.md (no orphan nobody can find).
#   4. A docs file with `paths:` front matter has a symlink in .claude/rules/,
#      and every .claude/rules/ entry is such a symlink into docs/. A rule
#      without `paths:` would load into EVERY session, so it is an error.
#   5. Every nested AGENTS.md (Codex's per-directory hook) is a symlink into docs/.
#   6. Every `paths:` glob matches at least one file, so a rename cannot
#      silently turn a rule off.
#
# Usage: check.pl <max-bytes>      Run from the repository root.
use strict;
use warnings;
use Cwd qw(realpath);
use File::Find;

my ($max_bytes) = @ARGV;
die "usage: check.pl <max-bytes>\n" unless defined $max_bytes;

my @errors;
sub fail { push @errors, join '', @_ }

sub slurp {
    my ($file) = @_;
    open my $fh, '<:raw', $file or die "open $file: $!\n";
    local $/;
    return scalar <$fh>;
}

# --- 1. size -----------------------------------------------------------------
my $agents = slurp('AGENTS.md');
my $size   = length $agents;
if ($size > $max_bytes) {
    fail "AGENTS.md is $size bytes, over the budget of $max_bytes.\n"
       . "  Codex silently truncates AGENTS.md past 32768 bytes, and this repository keeps\n"
       . "  it far smaller on purpose. Move the detail to docs/<topic>.md and leave an\n"
       . "  index row here.\n";
}
print "AGENTS.md: $size / $max_bytes bytes\n";

# --- 2. + 3. pointers in both directions ---------------------------------------
my %named;
# matches:     Full detail: `docs/nix-cache.md`.   ->  $1 eq "docs/nix-cache.md"
$named{$1}++ while $agents =~ m{`(docs/[a-zA-Z0-9_.-]+\.md)`}g;
my %docs = map { $_ => 1 } glob 'docs/*.md';
fail "AGENTS.md names $_, which does not exist\n"             for grep { !$docs{$_} } sort keys %named;
fail "$_ is not named in AGENTS.md (add it to the index)\n"   for grep { !$named{$_} } sort keys %docs;

# --- front matter of every docs file ---------------------------------------------
# matches:     ---\npaths:\n  - "infra/**"\n---   ->  ("infra/**")
my %paths_of;
for my $doc (sort keys %docs) {
    my $text = slurp($doc);
    if ($text =~ m{\A---\n paths: \n (?<list> (?: \s+ - \s+ "[^"\n]+" \n )+ ) ---\n}x) {
        $paths_of{$doc} = [ $+{list} =~ m{"([^"\n]+)"}g ];
    }
}

# --- 4. .claude/rules ---------------------------------------------------------
my %ruled;
for my $rule (sort glob '.claude/rules/*.md') {
    unless (-l $rule) { fail "$rule is not a symlink (single source of truth is docs/)\n"; next }
    my $real = realpath($rule);
    my $root = realpath('.');
    (my $rel = $real // '') =~ s{^\Q$root\E/}{};
    unless ($rel =~ m{^docs/[^/]+\.md$}) { fail "$rule does not resolve into docs/ (got '$rel')\n"; next }
    $ruled{$rel}++;
    fail "$rule -> $rel has no `paths:` front matter; it would load into every session\n"
        unless $paths_of{$rel};
}
fail "$_ has `paths:` front matter but no symlink in .claude/rules/\n"
    for grep { !$ruled{$_} } sort keys %paths_of;

# --- 5. nested AGENTS.md ------------------------------------------------------------
my @files;
find({
    no_chdir => 1,
    wanted   => sub {
        if (-d $_ && $_ =~ m{(?:^|/)(?:\.git|node_modules|result)$}) { $File::Find::prune = 1; return }
        return unless -f $_ || -l $_;
        (my $p = $_) =~ s{^\./}{};
        push @files, $p;
    },
}, '.');
for my $f (sort @files) {
    next unless $f =~ m{/AGENTS\.md$};
    unless (-l $f) { fail "$f is a regular file; make it a symlink into docs/ (one source)\n"; next }
    my $root = realpath('.');
    (my $rel = realpath($f) // '') =~ s{^\Q$root\E/}{};
    fail "$f does not resolve into docs/ (got '$rel')\n" unless $rel =~ m{^docs/[^/]+\.md$};
}

# --- 6. every glob matches something --------------------------------------------
# matches:     modules/**/foo-*.nix   ->  ^modules/(?:.*/)?foo-[^/]*\.nix$
sub glob_re {
    my ($g) = @_;
    my $re = '';
    for my $tok (split m{(\*\*/|\*\*|\*|\?)}, $g) {
        if    ($tok eq '**/') { $re .= '(?:.*/)?' }
        elsif ($tok eq '**')  { $re .= '.*' }
        elsif ($tok eq '*')   { $re .= '[^/]*' }
        elsif ($tok eq '?')   { $re .= '[^/]' }
        else                  { $re .= quotemeta $tok }
    }
    return qr/^$re$/;
}
for my $doc (sort keys %paths_of) {
    for my $g (@{ $paths_of{$doc} }) {
        my $re = glob_re($g);
        fail "$doc: glob \"$g\" matches no file in the repository\n" unless grep { $_ =~ $re } @files;
    }
}

if (@errors) {
    print STDERR "agents-md check failed:\n";
    print STDERR "  - $_" for @errors;
    exit 1;
}
printf "%d docs files, all named in AGENTS.md; %d path-scoped rules linked; %d globs match.\n",
    scalar keys %docs, scalar keys %ruled, scalar map { @$_ } values %paths_of;
