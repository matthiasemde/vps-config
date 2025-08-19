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
      defaultConfig = pkgs.writeText "frps.toml" ''
        [common]
        # The port frpc clients will connect to
        bind_port = 7000

        # Enable dashboard to monitor connections
        dashboard_port = 7500
        dashboard_user = "minad"
        dashboard_pwd = "{{ .Envs.FRP_DASHBOARD_PWD }}"

        # Optional: authentication token (must match in frpc)
        # This secures the tunnel so random people can’t connect
        token = "{{ .Envs.FRP_TOKEN }}"
      '';
      configDerivation = pkgs.runCommand "frp-config" { } ''
        mkdir -p $out/etc/frp
        cp ${defaultConfig} $out/etc/frp/frps.toml
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
