{ ... }:
{
  flake.modules.homeManager.boundary = { config, pkgs, ... }:
    let
      mysqladminPath = "${pkgs.mariadb.client}/bin/mysqladmin";
      redisCliPath = "${pkgs.redis}/bin/redis-cli";
      boundaryPath = "${pkgs.boundary}/bin/boundary";
      pm2Path = "${pkgs.pm2}/bin/pm2";

      # Services list and cluster URL are decrypted from SOPS at activation. The
      # services JSON (name, type, port, targetId per entry) is inlined into the
      # PM2 ecosystem.config.js via sops-nix placeholder substitution; the JS
      # runtime maps it to PM2 app definitions. Cluster URL is read by +boundary-login.
      clusterUrlFile = config.sops.secrets.boundary_cluster_url.path;
      ecosystemPath = "${config.xdg.configHome}/boundary-pm2/ecosystem.config.js";
      healthcheckScriptPath = "${boundaryPm2Package}/libexec/boundary-healthcheck.py";

      boundaryPm2Package = pkgs.stdenv.mkDerivation {
        name = "boundary-pm2";
        nativeBuildInputs = [ pkgs.makeWrapper ];
        dontUnpack = true;

        installPhase = ''
                    mkdir -p $out/libexec $out/bin

                    cat > $out/libexec/boundary-healthcheck.py <<'PYEOF'
          #!${pkgs.python3}/bin/python3
          import subprocess
          import sys
          import time
          import socket
          import argparse
          import signal

          BOUNDARY = "${boundaryPath}"
          MYSQLADMIN = "${mysqladminPath}"
          REDIS_CLI = "${redisCliPath}"


          def tnsping(db_addr, db_port, db_timeout=1):
              packet = (
                  b"\x00W\x00\x00\x01\x00\x00\x00\x018\x01,\x00\x00\x08\x00\x7f\xff"
                  b"\x7f\x08\x00\x00\x01\x00\x00\x1d\x00:\x00\x00\x00\x00\x00\x00"
                  b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x190\x00\x00\x00\x8d"
                  b"\x00\x00\x00\x00\x00\x00\x00\x00(CONNECT_DATA=(COMMAND=ping))"
              )
              try:
                  with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                      sock.settimeout(db_timeout)
                      sock.connect((db_addr, int(db_port)))
                      sock.send(packet)
                      data = sock.recv(4096)
                      if not data:
                          return False
                      recv = data[12:].decode("utf-8", errors="ignore")
                      return "(DESCRIPTION=(TMP=)(VSNNUM=0)(ERR=0)(ALIAS=LISTENER))" in recv
              except Exception:
                  return False


          def check_mysql(port):
              try:
                  result = subprocess.run(
                      [MYSQLADMIN, "-h", "127.0.0.1", "-P", str(port), "ping", "--connect-timeout=3"],
                      capture_output=True, text=True
                  )
                  out = (result.stdout + result.stderr).lower()
                  if "mysqld is alive" in out or "access denied" in out:
                      return True
                  return result.returncode == 0
              except Exception:
                  return False


          def check_redis(port):
              try:
                  result = subprocess.run(
                      [REDIS_CLI, "-h", "127.0.0.1", "-p", str(port), "ping"],
                      capture_output=True, text=True
                  )
                  out = (result.stdout + result.stderr).strip().upper()
                  return "PONG" in out or "NOAUTH" in out
              except Exception:
                  return False


          def check_generic(port, timeout=3):
              try:
                  with socket.create_connection(("127.0.0.1", int(port)), timeout=timeout):
                      return True
              except Exception:
                  return False


          def main():
              parser = argparse.ArgumentParser()
              parser.add_argument("--target-id", required=True)
              parser.add_argument("--port", required=True, type=int)
              parser.add_argument("--cluster-url", required=True)
              parser.add_argument("--type", required=True, choices=["oracle", "mysql", "redis", "generic"])
              args = parser.parse_args()

              print(f"Starting Boundary proxy for {args.type} on port {args.port}...", flush=True)

              cmd = [
                  BOUNDARY, "connect",
                  "-target-id", args.target_id,
                  "-listen-port", str(args.port),
                  "-listen-addr", "127.0.0.1",
                  "-addr", args.cluster_url,
              ]

              proc = subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr)

              def _terminate(*_):
                  if proc.poll() is None:
                      proc.terminate()
                      try:
                          proc.wait(timeout=5)
                      except subprocess.TimeoutExpired:
                          proc.kill()
                  sys.exit(0)

              signal.signal(signal.SIGTERM, _terminate)
              signal.signal(signal.SIGINT, _terminate)

              try:
                  time.sleep(2)
                  while True:
                      if proc.poll() is not None:
                          print("Boundary process exited unexpectedly.", flush=True)
                          sys.exit(1)

                      if args.type == "oracle":
                          healthy = tnsping("127.0.0.1", args.port)
                      elif args.type == "mysql":
                          healthy = check_mysql(args.port)
                      elif args.type == "redis":
                          healthy = check_redis(args.port)
                      else:
                          healthy = check_generic(args.port)

                      if not healthy:
                          print(f"Health check failed for {args.type} on port {args.port}. Restarting...", flush=True)
                          _terminate()

                      time.sleep(10)

              finally:
                  _terminate()


          if __name__ == "__main__":
              main()
          PYEOF
                    chmod +x $out/libexec/boundary-healthcheck.py

                    cat > $out/bin/+boundary-login <<'EOF'
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          if [[ ! -r "${clusterUrlFile}" ]]; then
            echo "Boundary cluster URL secret not readable at ${clusterUrlFile}" >&2
            echo "Ensure sops-nix has decrypted boundary_cluster_url (re-run darwin-rebuild switch)." >&2
            exit 1
          fi
          url=$(< "${clusterUrlFile}")
          echo "Authenticating with Boundary..."
          ${boundaryPath} authenticate oidc -addr "$url"
          echo "Restarting Boundary connections..."
          ${pm2Path} restart ${ecosystemPath}
          echo "Done. Login in the browser and use '+boundary-status' to check."
          EOF
                    chmod +x $out/bin/+boundary-login

                    cat > $out/bin/+boundary-connect <<'EOF'
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          echo "Starting Boundary connections via PM2..."
          ${pm2Path} start ${ecosystemPath}
          echo "Done. Use '+boundary-status' to check."
          EOF
                    chmod +x $out/bin/+boundary-connect

                    cat > $out/bin/+boundary-disconnect <<'EOF'
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          echo "Stopping Boundary connections..."
          ${pm2Path} delete ${ecosystemPath} 2>/dev/null || true
          EOF
                    chmod +x $out/bin/+boundary-disconnect

                    cat > $out/bin/+boundary-restart <<'EOF'
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          echo "Restarting Boundary connections..."
          ${pm2Path} restart ${ecosystemPath}
          EOF
                    chmod +x $out/bin/+boundary-restart

                    cat > $out/bin/+boundary-reset <<'EOF'
          #!${pkgs.bash}/bin/bash
          set -euo pipefail
          pm2="${pm2Path}"

          "$pm2" delete all || true
          "$pm2" kill || true

          rm -rf ~/.pm2

          "$pm2" ping
          "$pm2" ls
          EOF
                    chmod +x $out/bin/+boundary-reset

                    cat > $out/bin/+boundary-status <<'EOF'
          #!${pkgs.bash}/bin/bash
          pm2="${pm2Path}"

          status="$("$pm2" status 2>/dev/null || true)"

          printf '%s\n' "$status" | head -n 3
          printf '%s\n' "$status" | grep "boundary-" || true
          printf '%s\n' "$status" | tail -n 1
          EOF
                    chmod +x $out/bin/+boundary-status
        '';
      };

      deps = with pkgs; [
        pm2
        boundary
        python3
        mariadb.client
        redis
      ];

    in
    {
      sops.templates."boundary-pm2-ecosystem.config.js" = {
        path = ecosystemPath;
        mode = "0644";
        content = ''
          const services = ${config.sops.placeholder.boundary_services};
          module.exports = {
            apps: services.map(function (s) {
              return {
                name: "boundary-" + s.name,
                script: "${healthcheckScriptPath}",
                args: "--target-id " + s.targetId +
                      " --port " + s.port +
                      " --type " + s.type +
                      " --cluster-url ${config.sops.placeholder.boundary_cluster_url}",
                autorestart: true,
                max_restarts: 10,
                restart_delay: 5000,
                out_file: "/dev/stdout",
                error_file: "/dev/stderr"
              };
            })
          };
        '';
      };

      home.packages = [ boundaryPm2Package ] ++ deps;
      launchd.agents.pm2 = {
        enable = true;
        config = {
          ProgramArguments = [ "${pm2Path}" "resurrect" "--no-daemon" ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/pm2.out.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/pm2.err.log";
        };
      };
    };
}
