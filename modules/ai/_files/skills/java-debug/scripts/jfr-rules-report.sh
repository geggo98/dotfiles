#!/bin/zsh
# Runs the JDK Mission Control "Automated Analysis" rules on a .jfr file WITHOUT the GUI
# and writes the result as an HTML report.
#
# usage: jfr-rules-report.sh [--jmc-plugins DIR] [--java JAVA_BIN] <recording.jfr> [report.html]
#
# The rules engine is not a separate download: it ships inside the JMC application. The script
# builds the class path from the JMC plugin directory:
#   macOS (Homebrew cask jdk-mission-control):
#     .../JDK Mission Control.app/Contents/Eclipse/plugins
#   Linux (unpacked JMC tarball): <jmc>/plugins   -> pass it with --jmc-plugins or $JMC_PLUGINS
#
# The class used here is an internal part of JMC, not a supported command line: it can change with
# any JMC release. Measured with 9.1.1 on macOS only; the Linux layout is not measured.
# The HTML report is written with mode 0600. Treat it like the recording.
#
# Exit: 0 ok, 1 failure (missing JARs, JMC not found, report not written), 2 usage.
# Measured: JMC 9.1.1 plugin JARs with Temurin 17 and 25, 3.7 MB recording -> 125 KB HTML.
emulate -L zsh
setopt extendedglob null_glob err_return pipe_fail no_unset

prog=${0:t}   # inside a function $0 is the function name, so capture it here
usage() { print -u2 "usage: $prog [--jmc-plugins DIR] [--java JAVA_BIN] <recording.jfr> [report.html]"; exit 2 }

plugins=${JMC_PLUGINS:-}
java=${JAVA_BIN:-java}
while (( $# )); do
  case $1 in
    --jmc-plugins) (( $# >= 2 )) || usage; plugins=$2; shift 2 ;;
    --java)        (( $# >= 2 )) || usage; java=$2; shift 2 ;;
    -h|--help)     usage ;;
    --)            shift; break ;;
    -*)            print -u2 "unknown option: $1"; usage ;;
    *)             break ;;
  esac
done
(( $# >= 1 && $# <= 2 )) || usage
jfr=$1
out=${2:-${jfr:r}-rules.html}
[[ -f $jfr ]] || { print -u2 "error: $jfr not found"; exit 1 }

# Find the plugin directory when it was not given. Order: Homebrew Caskroom (version directories
# sorted numerically, so 9.1.10 comes after 9.1.9; the sort is per Caskroom root, so any version
# under /usr/local comes after every version under /opt/homebrew), /Applications, ~/Applications. The LAST
# existing location wins. (zsh glob qualifiers such as (n) only work at the END of a pattern.)
if [[ -z $plugins ]]; then
  typeset -a cands
  for root in /opt/homebrew/Caskroom/jdk-mission-control /usr/local/Caskroom/jdk-mission-control; do
    for version_dir in $root/*(N/n); do
      cands+=( $version_dir/*/JDK\ Mission\ Control.app/Contents/Eclipse/plugins(N) )
    done
  done
  cands+=( /Applications/JDK\ Mission\ Control.app/Contents/Eclipse/plugins(N) )
  cands+=( ~/Applications/JDK\ Mission\ Control.app/Contents/Eclipse/plugins(N) )
  (( $#cands )) && plugins=$cands[-1]
fi
[[ -n $plugins && -d $plugins ]] || {
  print -u2 "error: JMC plugin directory not found. Install JMC (brew install --cask jdk-mission-control) or pass --jmc-plugins DIR."
  exit 1
}

# The six JARs the report needs. Without lz4 and the OWASP encoder the JVM fails with
# ClassNotFoundException (net.jpountz.lz4..., org.owasp.encoder.Encode).
typeset -a patterns jars missing
patterns=(
  'org.openjdk.jmc.common_*.jar'
  'org.openjdk.jmc.flightrecorder_[0-9]*.jar'
  'org.openjdk.jmc.flightrecorder.rules_[0-9]*.jar'
  'org.openjdk.jmc.flightrecorder.rules.jdk_[0-9]*.jar'
  'lz4*.jar'
  'org.owasp.encoder_*.jar'
)
for p in $patterns; do
  found=( ${plugins}/${~p}(N) )
  if (( $#found == 1 )); then jars+=( $found[1] ); else missing+=( "$p ($#found matches)" ); fi
done
(( $#missing == 0 )) || { print -u2 "error: need exactly one JAR per pattern in $plugins; problems: ${(j:, :)missing}"; exit 1 }

command -v $java >/dev/null || { print -u2 "error: java not found ($java)"; exit 1 }

umask 077   # the report quotes JVM arguments and system properties: as sensitive as the recording
tmp=${out}.tmp.$$
# EXIT cleans up; INT/TERM must exit themselves, or zsh resumes the script after the trap.
trap 'rm -f -- $tmp' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# JMC prints harmless WARNINGs for event fields it does not know (e.g. 'virtual' on thread
# in recordings from newer JDKs). They stay on stderr.
$java -cp "${(j.:.)jars}" org.openjdk.jmc.flightrecorder.rules.report.html.JfrHtmlRulesReport "$jfr" "$tmp"
[[ -s $tmp ]] || { print -u2 "error: no report was written"; exit 1 }
mv -f -- "$tmp" "$out"
print -- "$out"
