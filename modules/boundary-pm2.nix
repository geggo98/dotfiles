{ config, lib, pkgs, ... }:

let
  clusterUrl = "https://boundary.kfz.check24.de";

  # Configuration from BOUNDARY.sec.md
  services = [
    { name = "legacy-prod-mysql";            type = "mysql";  port = 20103; targetId = "ttcp_HH0Azbwwdr"; }
    { name = "legacy-prod-oracle-primary";  type = "oracle"; port = 20100; targetId = "ttcp_1MVMF9YvMa"; }
    { name = "legacy-prod-oracle-secondary"; type = "oracle"; port = 20101; targetId = "ttcp_sBX89EtcXI"; }
    { name = "legacy-prod-redis";            type = "redis";  port = 20208; targetId = "ttcp_ksq92OtmQ9"; }
    { name = "legacy-staging-mysql";         type = "mysql";  port = 10104; targetId = "ttcp_2cmuAi8cAN"; }
    { name = "legacy-staging-oracle-primary"; type = "oracle"; port = 10100; targetId = "ttcp_GicGSfQzIY"; }
    { name = "legacy-staging-redis";         type = "redis";  port = 10208; targetId = "ttcp_2ZRc80yimu"; }
  ];

  outPath = builtins.placeholder "out";

  mysqladminPath = "${pkgs.mariadb.client}/bin/mysqladmin";
  redisCliPath = "${pkgs.redis}/bin/redis-cli";
  boundaryPath = "${pkgs.boundary}/bin/boundary";

  servicesJs = lib.concatStringsSep ",\n" (map (s: ''    {
      name: "boundary-${s.name}",
      script: "${outPath}/libexec/boundary-healthcheck.py",
      args: "--target-id ${s.targetId} --port ${toString s.port} --type ${s.type} --cluster-url ${clusterUrl}",
      autorestart: true,
      max_restarts: 10,
      restart_delay: 5000,
      out_file: "/dev/stdout",
      error_file: "/dev/stderr"
    }'') services);

  # Package containing healthcheck, PM2 ecosystem config, and helper scripts
  boundaryPm2Package = pkgs.stdenv.mkDerivation {
    name = "boundary-pm2";
    nativeBuildInputs = [ pkgs.makeWrapper ];
    dontUnpack = true;

    installPhase = ''
      mkdir -p $out/libexec $out/share/boundary-pm2 $out/bin

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

      cat > $out/share/boundary-pm2/ecosystem.config.js <<'JSEOF'
module.exports = {
  apps: [
${servicesJs}
  ]
}
JSEOF

      cat > $out/bin/+boundary-login <<'EOF'
#!${pkgs.bash}/bin/bash
echo "Authenticating with Boundary..."
${boundaryPath} authenticate oidc -addr "${clusterUrl}"
EOF
      chmod +x $out/bin/+boundary-login

      cat > $out/bin/+boundary-connect <<'EOF'
#!${pkgs.bash}/bin/bash
set -euo pipefail
echo "Starting Boundary connections via PM2..."
${pkgs.nodePackages.pm2}/bin/pm2 start ${outPath}/share/boundary-pm2/ecosystem.config.js
echo "Done. Use '+boundary-status' to check."
EOF
      chmod +x $out/bin/+boundary-connect

      cat > $out/bin/+boundary-disconnect <<'EOF'
#!${pkgs.bash}/bin/bash
set -euo pipefail
echo "Stopping Boundary connections..."
apps="${lib.concatStringsSep " " (map (s: "boundary-${s.name}") services)}"
for app in $apps; do
  ${pkgs.nodePackages.pm2}/bin/pm2 delete "$app" 2>/dev/null || true
done
EOF
      chmod +x $out/bin/+boundary-disconnect

      cat > $out/bin/+boundary-restart <<'EOF'
#!${pkgs.bash}/bin/bash
set -euo pipefail
echo "Restarting Boundary connections..."
${pkgs.nodePackages.pm2}/bin/pm2 restart ${outPath}/share/boundary-pm2/ecosystem.config.js
EOF
      chmod +x $out/bin/+boundary-restart

      cat > $out/bin/+boundary-status <<'EOF'
#!${pkgs.bash}/bin/bash
${pkgs.nodePackages.pm2}/bin/pm2 status | grep "boundary-" || true
EOF
      chmod +x $out/bin/+boundary-status
    '';
  };

  deps = with pkgs; [
    nodePackages.pm2
    boundary
    python3
    mariadb.client
    redis
  ];

in
{
  home.packages = [ boundaryPm2Package ] ++ deps;
}
