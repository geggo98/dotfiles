Applies to: macOS with OrbStack; Telepresence. Read this only if OrbStack or Telepresence is in use.

# OrbStack and Telepresence specifics

OrbStack is a container and VM runtime for macOS with a built-in
single-node Kubernetes cluster. Telepresence is a tool that routes cluster
traffic to and from a process on the Mac. A Telepresence *intercept*
redirects the traffic that a Service sends to one container port, so that
it reaches the Mac instead of the pod.

**TL;DR:** OrbStack makes cluster DNS names reachable from the Mac, so you
often need no port-forward. Container file paths change on every pod
restart, but volume paths stay. Some binaries from the Nix store
(`/nix/store`, installed with the Nix package manager) cannot reach cluster
IPs. `kubectl port-forward` reaches only listeners on IPv4 `127.0.0.1` or a
wildcard address. Telepresence intercepts have several sharp edges. The
file that `telepresence intercept --env-file <file>` writes holds the full
pod environment: keep it at 0600 and never print it.

## OrbStack

**Cluster names resolve on the Mac.** OrbStack exposes Kubernetes services
and pods directly: `<svc>.<ns>.svc.cluster.local`, ClusterIPs and pod IPs
work from the Mac. `*.k8s.orb.local` is a wildcard domain for LoadBalancer
services such as an Ingress controller, not a name per namespace. For a
service that DNS reaches, no `kubectl port-forward` is needed. This changes
the security picture: a listener with a Service is reachable from the Mac
and from every pod. Security rule 1 in
[SKILL.md, Security rules](../SKILL.md#security-rules) (bind to loopback)
therefore still applies.

**`kubectl port-forward` connects over IPv4 only.** On OrbStack's Docker
runtime, the container runtime on the Kubernetes node (not a process in the
pod) relays the forward through socat, a relay for TCP connections, with
the target `TCP4:localhost:<port>`. The connection arrives in the pod from
`127.0.0.1`, like a local connection. A listener bound only to `::1` or
only to the pod IP is unreachable, and the first refused connection ends
the whole port-forward with `error: lost connection to pod` (all measured
2026-11-15 on OrbStack Kubernetes with kubectl port-forward, Kubernetes
1.36.5). Details and consequences are in
[jmx-jolokia-ports](jmx-jolokia-ports.md#what-port-forward-reaches).

**Container file paths change on every pod restart.** OrbStack shows
container file systems under

```
~/OrbStack/docker/containers/k8s_<ct>_<pod>_<ns>_<uid>_<restarts>
```

`<ct>` is the container name from the pod spec, `<pod>` the pod name,
`<ns>` the namespace, `<uid>` the pod UID and `<restarts>` the restart
counter of the container.
The pod UID and the restart counter are part of the name, so the path is
new after each restart. Go through a symlink that you refresh after a
restart. Volume paths `~/OrbStack/docker/volumes/<name>` are stable.

**Held file handles on container paths can go stale.** A file that stays
open through the container path gets `ESTALE` ("stale file handle") when a
restart or recreation gives the container a new directory under
`~/OrbStack/docker/containers/`. The same file through the volume path
does not. JFR aborts the JVM on that error if the file is in its
repository, the directory where JFR writes chunk files while it records. Every recording writes to its repository unless it sets
`disk=false`, an option of `-XX:StartFlightRecording` and of
`jcmd <pid> JFR.start`. Without `repository=`, an option of
`-XX:FlightRecorderOptions`, the repository is
`<java.io.tmpdir>/<timestamp>_<pid>/` (measured 2026-11-15 on Temurin 11,
17, 21 and 25, in a container). Keep a JFR repository on a local disk or a
volume path, so that the JVM survives a container change. Details are in
`java-debug`, [jfr.md, section 10](../../java-debug/references/jfr.md#10-pitfalls-measured-in-containers-and-on-network-file-systems),
item 1 "JFR repository on a file system that can go stale kills the JVM".

**Binaries from the Nix store and cluster IPs.** Observed, cause not
confirmed: Bun (a JavaScript runtime) and Python from the Nix store got `ECONNREFUSED` when they
connected to cluster IPs, while `nc` and Apple's binaries worked. The macOS
"Local Network" permission is a suspect: it is the per-app privacy
permission for access to the local network (System Settings > Privacy &
Security > Local Network), and unsigned binaries from the Nix store may
never get the prompt that grants it. Workaround: use a tool from the macOS
base system, such as `/usr/bin/curl` or `/usr/bin/nc`, instead of the same
tool from `/nix/store`, or fall back to `kubectl port-forward`. Because one
refused connection ends the whole port-forward (see above), forward one
port per command.

**Do not forward to local port 5000 or 7000.** ControlCenter (the AirPlay
Receiver) holds `*:5000` and `*:7000` on the Mac. While the forward runs,
the pod answers. After the forward dies, a client reaches ControlCenter and
hangs without an error message (measured 2026-11-15 on OrbStack Kubernetes
with kubectl port-forward).

**IPv6 can lose large packets.** The IPv6 path to a `.k8s.orb.local` name
can drop large packets (a path-MTU hole). The symptom is HTTP 200 with curl
exit 28 and 0 bytes of body. Exit 28 means the operation timed out: the
headers arrived, but the body never did. Which address family a client picks is not
deterministic, so it looks sporadic. Use `curl -4`, and check with:

```bash
curl -s -o /dev/null -w 'ip=%{remote_ip} exit=%{exitcode} size=%{size_download}\n' http://<host>.k8s.orb.local/
```

**Sleep.** A Mac that sleeps can pause or kill pods of the local cluster.
Plan long measurements around it, and check restart counters before you
compare results.

## Telepresence 2

| Pitfall | What to do |
|---|---|
| Namespace of an intercept | Give the namespace at connect time: `telepresence connect --namespace <ns>`. Whether `intercept` itself takes `--namespace` depends on the version: the CLI reference page "telepresence intercept" for Telepresence 2.33 (<https://telepresence.io/docs/reference/cli/telepresence_intercept>, checked 2026-11-15) lists it ("Defaults to the connected namespace"), but some 2.x releases reject it (not measured; check `telepresence intercept --help`). Changing the context default (`kubectl config set-context --current --namespace=<ns>`) also works and is what IDE plugins need that start Telepresence without passing a namespace (for example the Telepresence plugins for IntelliJ or VS Code), but it edits the user's kubeconfig: ask first. |
| A pod behind several Services | Name the Service: `--service <svc>`. |
| One intercept catches the whole container port | All traffic to that port goes to the Mac, not only your requests. Tell other users of the cluster, because their requests reach your Mac too. |
| `Executable mismatch` | Telepresence compares the path string of its binary. A symlink and the resolved path under `/nix/store` count as different. Call it through the same path every time. |
| Orphaned intercept | The Service becomes a black hole: requests go to a Mac process that no longer runs. `telepresence leave <workload>`, or `telepresence quit` and reconnect. |
| Tailscale | Tailscale (a WireGuard-based VPN client) and Telepresence both manage DNS on the Mac and get in each other's way. Disconnect one of them. |
| `telepresence connect` | Starts a root daemon and needs sudo, so it needs a TTY. An agent without a terminal cannot run it: hand it to the user. |
| `--env-file` | `telepresence intercept --env-file <file>` writes the intercepted pod's environment variables to `<file>`. The file holds the whole pod environment, secrets included. Create it with mode 0600 and never print it, so that the secrets stay out of logs and transcripts. |
| File mounts with OrbStack | By default, `telepresence intercept` mounts the pod's volumes on the Mac. Use `telepresence intercept --mount=false`. The container files are already visible through OrbStack's container paths (above). |

**Never pass `telepresence list --output json` on unfiltered.** It prints
the full environment of every intercepted pod in clear text (measured once
on a local cluster: 385 variables, passwords among them; date not
recorded). Reduce the environment to variable NAMES before it is shown,
logged or written to a report.
