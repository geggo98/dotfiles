{ inputs, ... }:
{
  flake.modules.homeManager.yt-dlp = { pkgs, ... }:
    let
      yt-dlp-pkgs = inputs.nixpkgs-yt-dlp.legacyPackages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      # ffmpeg is essential for yt-dlp: embed-thumbnail/embed-subs and
      # merging separate audio/video streams require it. The headless
      # variant ships all codecs/containers without the GUI libs.
      # aria2c (configured as downloader below) is enabled globally via
      # programs.aria2 in modules/packages.nix; if absent, yt-dlp falls
      # back to its built-in downloader — no hard dependency.
      home.packages = with pkgs; [ ffmpeg-headless ];

      programs.yt-dlp = {
        enable = true;
        package = yt-dlp-pkgs.yt-dlp;
        settings = {
          embed-thumbnail = true;
          embed-subs = true;
          sub-langs = "all";
          downloader = "aria2c";
          downloader-args = "aria2c:'-c -x8 -s8 -k1M'";
        };
      };

      programs.fish = {
        shellAbbrs = {
          "+yt-dlp" = "yt-dlp -i --format 'bestvideo[ext=mp4]+bestaudio/best[ext=m4a]/best' --merge-output-format mp4 --no-post-overwrites --output ~/Downloads/yt-dlp/'%(title)s.%(ext)s'";
          "+yt-dlp-info" = ''yt-dlp --ignore-config --skip-download --no-playlist --print "Title:       %(title)s" --print "Uploader:    %(uploader)s" --print "Upload Date: %(upload_date)s" --print "Duration:    %(duration_string)s" --print "Views:       %(view_count)s" --print "URL:         %(webpage_url)s" --print "" --print "%(description)s"'';
        };
        functions = {
          "+yt-dlp-transcript" = {
            body = builtins.readFile ./_files/shell/yt-dlp-transcript.fish;
            description = "Download subtitles (VTT) and write a cleaned transcript .txt into $TMPDIR/yt-dlp-transcript (ignores global yt-dlp config; -q/--stdout for pipe use)";
          };
        };
      };
    };
}
