# 1Password's SSH agent config.
#
# WHY THIS EXISTS AT ALL: `~/.config/1Password/ssh/agent.toml` decides which
# vaults the agent will offer keys from. Absent, it defaults to the Personal /
# Private vault ONLY — so a key kept anywhere else is simply never offered, and
# the failure looks like a server problem. It bit exactly that way when the
# IONOS VPS key was moved into the "Homelab" vault: `ssh-add -l` showed nothing,
# the server refused the login, and nothing about the server was wrong.
#
# It is per-machine state that 1Password does not sync, so every new Mac starts
# without it. That is the case for automating it here rather than remembering.
#
# SAFE TO MANAGE DECLARATIVELY, verified rather than assumed:
#   * 1Password only READS this file — the docs describe user edits only, and
#     the file's mtime stayed at the hand-edit while the agent loaded keys and
#     signed repeatedly for half an hour afterwards. A read-only /nix/store
#     symlink is therefore fine.
#   * "You don't need to restart the SSH agent each time you edit the agent
#     config file" — changes are picked up immediately. Confirmed: the new vault
#     appeared in `ssh-add -l` the moment the file changed, with no restart.
#   * No documented requirement on permissions or on it being a real file.
#
# If 1Password ever gains a UI that writes this file, this module has to go —
# the symptom would be settings that silently revert on the next activation.
{ ... }:
let
  # ORDER MATTERS, and not only cosmetically. ssh offers agent keys in this
  # order and gives up after MaxAuthTries (6 by default, and file-based
  # identities count towards it too). A vault that grows large can therefore
  # starve a later one of its attempt. If that ever happens, the fix is a
  # per-host block in ~/.ssh/config with IdentityFile + IdentitiesOnly — not
  # reshuffling this list, which would only move the problem.
  #
  # "Persönlich" is the German name of the personal vault; it is a display name,
  # so it changes if the vault is renamed or the 1Password language changes.
  vaults = [
    "Persönlich"
    "Homelab" # machines managed from this repo — currently the IONOS VPS
  ];

  agentToml = ''
    # Managed by nix-darwin (modules/onepassword.nix). Edits here are lost on
    # the next `just switch`; change the `vaults` list in that module instead.
    #
    # Without this file the agent offers keys from the personal vault ONLY, and
    # a key in any other vault is never even offered to the server.
  '' + builtins.concatStringsSep "" (map
    (v: ''

      [[ssh-keys]]
      vault = "${v}"
    '')
    vaults);
in
{
  flake.modules.homeManager.onepassword = { ... }: {
    xdg.configFile."1Password/ssh/agent.toml" = {
      text = agentToml;

      # force, because both workstations already carry a hand-written file here
      # and home-manager otherwise refuses to clobber it ("Existing file would
      # be clobbered"). Note what this does: it deletes the target
      # unconditionally, file or symlink. That is acceptable precisely because
      # the content is not precious — it is a list of vault names, reproduced
      # above — but it does mean a local edit disappears without a word.
      force = true;
    };

    # NOT managed here: ~/.ssh/config, which carries the global `IdentityAgent`
    # line pointing at the agent socket. home-manager's `programs.ssh` generates
    # that file wholesale and would take the hand-maintained entries with it.
    # The two halves of "1Password provides my SSH keys" therefore live in
    # different places, which is worth knowing when only one of them is missing.
  };
}
