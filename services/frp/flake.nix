{
  description = "docker image flake for frps";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      frpPkg = pkgs.frp;
      configDerivation = pkgs.runCommand "frp-config" { } ''
        mkdir -p $out/etc/frp
        cp ${./frps.toml} $out/etc/frp/frps.toml
      '';
      frpsImage = pkgs.dockerTools.buildImage {
        name = "frps";
        tag  = frpPkg.version;
        copyToRoot = [ pkgs.bash frpPkg configDerivation ];
        config = {
          Cmd = [ "${frpPkg}/bin/frps" "-c" "/etc/frp/frps.toml" ];
        };
      };
    in {
      packages.${system}.frpsImage = frpsImage;
    };
}
