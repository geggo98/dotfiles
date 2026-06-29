{ ... }:
{
  # voxscriber — local speaker diarization (MLX Whisper + Pyannote).
  # https://pypi.org/project/voxscriber/
  #
  # mlx-whisper is not in nixpkgs, so we package its pure-Python wheel here
  # against nixpkgs' `mlx` core; voxscriber then pulls it in alongside the
  # already-packaged pyannote-audio/pydub/soundfile stack. Both wheels are
  # `py3-none-any`, so packaging is trivial — only the dependency closure
  # (torch/pyannote-audio/numba) is heavy. Apple-Silicon only (mlx), which
  # matches both hosts (aarch64-darwin); faster-whisper is excluded on this
  # platform by its env marker.
  flake.modules.homeManager.voxscriber = { pkgs, lib, ... }:
    let
      # All deps must share one interpreter; python313Packages is the set that
      # ships mlx + pyannote-audio in nixpkgs 26.05.
      py = pkgs.python313Packages;

      mlx-whisper = py.buildPythonPackage rec {
        pname = "mlx-whisper";
        version = "0.4.3";
        format = "wheel";
        src = pkgs.fetchPypi {
          pname = "mlx_whisper"; # wheel dist name (underscored)
          inherit version format;
          dist = "py3";
          python = "py3";
          hash = "sha256-a4K2WXqZRkOj5Ulse8IppnLlyjCEWEVb/idudq4CRIk=";
        };
        dependencies = with py; [
          mlx
          numba
          numpy
          torch
          tqdm
          more-itertools
          tiktoken
          huggingface-hub
          scipy
        ];
        # mlx propagates the Python `ninja` package, whose setup-hook would
        # otherwise hijack build/install to run ninja — but this is a prebuilt
        # wheel with nothing to compile, and the ninja binary isn't on PATH.
        dontUseNinjaBuild = true;
        dontUseNinjaInstall = true;
        pythonImportsCheck = [ "mlx_whisper" ];
        doCheck = false;
      };

      voxscriber = py.buildPythonApplication rec {
        pname = "voxscriber";
        version = "0.2.8";
        format = "wheel";
        src = pkgs.fetchPypi {
          inherit pname version format;
          dist = "py3";
          python = "py3";
          hash = "sha256-7IQh0yaaG7M21A3DHkX3Xqea76XbkAz7cAP2Cdi7WG8=";
        };
        dependencies = [ mlx-whisper ] ++ (with py; [
          pyannote-audio
          pydub
          python-dotenv
          rich
          soundfile
          tqdm
        ]);
        # pydub shells out to ffmpeg/ffprobe at runtime, and voxscriber-doctor
        # checks for them — inject ffmpeg onto the wrapped scripts' PATH.
        makeWrapperArgs = [
          "--prefix PATH : ${lib.makeBinPath [ pkgs.ffmpeg-headless ]}"
        ];
        # Same ninja-hook hijack reaches here via mlx-whisper → mlx (see above).
        dontUseNinjaBuild = true;
        dontUseNinjaInstall = true;
        pythonImportsCheck = [ "voxscriber" ];
        doCheck = false;
      };
    in
    {
      home.packages = [ voxscriber ];
    };
}
