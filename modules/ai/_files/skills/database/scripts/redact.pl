#!/usr/bin/env perl
# redact.pl — stdin → stdout filter that masks credentials. Used by _lib.sh
# (redact_stream); never put secrets on its command line.
#
# Two layers:
#   1. exact:     every value listed in $DB_REDACT_SECRETS (separated by \x1f),
#                 plus its URL-encoded and URL-decoded form, becomes ***
#   2. heuristic: well-known credential shapes, for when the value is unknown
#
# Works on bytes, not characters: query results may contain invalid UTF-8,
# and every pattern below is plain ASCII, so a lossless pass-through matters
# more than Unicode semantics here.
use strict;
use warnings;

$| = 1;

my %secret;
for my $raw (split /\x1f/, delete($ENV{DB_REDACT_SECRETS}) // '') {
    next unless length $raw;
    (my $decoded = $raw) =~ s/%(?<hex>[0-9A-Fa-f]{2})/chr hex $+{hex}/ge;
    (my $encoded = $raw) =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ge;
    $secret{$_} = 1 for grep { length } $raw, $decoded, $encoded;
}
# Longest first, so a DSN is masked as a whole before its password inside it.
my @secrets = sort { length $b <=> length $a } keys %secret;

my $in_pem = 0;
while (my $line = <STDIN>) {
    # -----BEGIN PRIVATE KEY----- … -----END PRIVATE KEY-----  (multi-line)
    if ($in_pem) {
        if ($line =~ /-----END [A-Z ]*PRIVATE KEY-----/) { $in_pem = 0 }
        next;
    }
    if ($line =~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) {
        $in_pem = 1;
        print "-----BEGIN PRIVATE KEY (redacted)-----\n";
        next;
    }

    $line =~ s/\Q$_\E/***/g for @secrets;

    # mysql://app:s3cret@db.example/x   ->  mysql://app:***@db.example/x
    # The password may contain an unencoded "@" or "/", so match up to the
    # LAST "@" of the whitespace-free token.
    $line =~ s{ (?<head> \b[A-Za-z][A-Za-z0-9+.-]*:// [^\s:/@]* : ) \S* @ }{$+{head}***@}gx;

    # Server=h;Password=s3cret;Uid=u   ->  Server=h;Password=***;Uid=u
    # password = 's3 cret'  /  --password=s3cret  /  &token=abc&x=1
    $line =~ s{
        (?<key> \b (?:pass(?:word|wd)?|pwd|secret|token|api[_-]?key|access[_-]?key|auth) [\w-]* \s* = \s* )
        (?: '[^']*' | "[^"]*" | [^\s;&,'"]+ )
    }{$+{key}***}gix;

    # CREATE USER x IDENTIFIED BY 's3cret'   ->  … IDENTIFIED BY '***'
    $line =~ s{ (?<kw> \bIDENTIFIED \s+ BY \s+ ) (?: '[^']*' | "[^"]*" | \S+ ) }{$+{kw}'***'}gix;

    # "api_token": "abc", "private_key": "-----BEGIN…\n…"   (JSON)
    $line =~ s{
        (?<key> " [^"\n]* (?:password|passwd|pwd|secret|token|private_key|api_key) [^"\n]* " \s* : \s* )
        " (?: [^"\\] | \\. )* "
    }{$+{key}"***"}gix;

    # mysql -pHUNTER2 db   /   sqlcmd -P HUNTER2     (argv echoed by a tool)
    $line =~ s{ (?<![\w-]) (?<flag> -p ) (?=\S) \S+ }{$+{flag}***}gx;
    $line =~ s{ (?<![\w-]) (?<flag> -P \s+ ) \S+ }{$+{flag}***}gx;

    print $line;
}
