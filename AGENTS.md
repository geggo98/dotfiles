# Repository Guidelines

## Project Structure & Module Organization
- `flake.nix` is the entry point; it wires `darwinConfigurations` and registers overlays.
- Global defaults live in `configuration.nix` and `darwin.nix`; shared Homebrew logic is in `modules/homebrew-common.nix`.
- `home.nix` defines the base Home Manager profile, with host overrides under `hosts/<serial>/{home,configuration,homebrew}.nix`.
- Dotfiles sit in `config/`; SOPS secrets live in `secrets/secrets.enc.yaml` and map to paths declared in `home.nix`.

## Build, Test, and Development Commands
- `nix flake update` refreshes inputs; `nix flake lock --update-input <name>` targets a single source.
- `nix build .#darwinConfigurations.DKL6GDJ7X1.system` (swap the hostname) ensures the configuration evaluates and builds without switching.
- `sudo darwin-rebuild switch --flake ~/.config/nix-darwin#FCX19GT9XR` applies the configuration to the active host; use `--dry-run` before switching on new machines.

## Coding Style & Naming Conventions
- Use two-space indentation and keep attribute sets alphabetized within logical groups to match the existing Nix style.
- Prefer descriptive attribute names and mirror host naming (`FCX19GT9XR`, `DKL6GDJ7X1`).
- Format Nix code with `nixpkgs-fmt` (`nix run nixpkgs#nixpkgs-fmt -- <files>`) before opening a pull request.

## Testing Guidelines
- Run `nix flake check` plus `nix build .#darwinConfigurations.<host>.system` for each affected host.
- Use `darwin-rebuild build --flake ~/.config/nix-darwin#<host>` or `--dry-run` to verify activations safely.
- Share `nix store diff-closures /run/current-system result` when explaining package deltas.

## Commit & Pull Request Guidelines
- Use Conventional Commits `type(scope): subject` in imperative present tense (≤72 chars); types include `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Reuse scopes such as `home`, `homebrew`, `darwin`, `flake`, `secrets`, `macos`, `env`, `project`, `docs`, and add host IDs when relevant; detail secrets or manual steps in the body and reference issues in the footer.
- Iterate with fixups (`git commit -m "fixup! …"`); run `git push --dry-run` and wait for explicit approval before pushing.
- Pull requests should outline impacted host(s), commands executed from the list above, and UI screenshots only when dotfiles change visible behavior.

## Secrets & Configuration Tips
- Ask the user to edit encrypted data with SOPS: `env SOPS_AGE_KEY=$(ssh-to-age -i ~/.ssh/id_ed25519_sops_nopw -private-key) sops edit secrets/secrets.enc.yaml`.
  You are inside a sandbox, sops won't work properly.
- Ensure new secrets are declared in `home.nix` with explicit paths and modes; avoid committing derived plaintext files.
- When provisioning a new machine, confirm the correct host serial directory under `hosts/` before switching to prevent cross-host contamination.
