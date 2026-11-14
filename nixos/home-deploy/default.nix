# Home's on-demand deploy (paulgsc/server, nix/modules/home-deploy.nix; its
# README, "Deploying to home"): when a client needs a newer server than home
# runs, file_host writes <storage>/deploy/wanted, and the path unit starts
# `envctl deploy --on-demand`, which applies main's release only for a higher
# contract epoch and rolls back whole if it doesn't come up. No timer, no
# polling. `make home-deploy` remains the way to move by hand; both keep their
# record in ~paulg/.local/state/server-deploy.
#
# The module comes from the `server` flake input, so the weekly lockfile PR is
# what moves it, like every other input.
{inputs, ...}: {
  imports = [inputs.server.nixosModules.home-deploy];

  services.home-deploy = {
    enable = true;
    # Runs `make` in the checkout: in the docker group, holding the age key.
    user = "paulg";
    checkout = "/home/paulg/dev/server";
    # STORAGE, as deploy/home/compose.sops.env sets it: file_host's database
    # directory, mounted at /app/dbs (read from the running container,
    # 2026-11-14).
    storage = "/mnt/storage/users/dev/databases/hopium";
  };
}
