{
  description = "Cardano Playground: cardano testnet clusters";

  inputs = {
    nixpkgs.follows = "cardano-parts/nixpkgs";
    nixpkgs-unstable.follows = "cardano-parts/nixpkgs-unstable";
    flake-parts.follows = "cardano-parts/flake-parts";
    cardano-parts.url = "github:input-output-hk/cardano-parts/next-2024-02-08";
    # cardano-parts.url = "path:/home/jlotoski/work/iohk/cardano-parts-wt/next-2024-02-08";

    # Local pins for additional customization:
    cardano-node.url = "github:IntersectMBO/cardano-node/8.1.2";
    cardano-node-821-pre.url = "github:IntersectMBO/cardano-node/8.2.1-pre";
    cardano-node-hd.url = "github:IntersectMBO/cardano-node/utxo-hd-8.2.1";
    cardano-node-bootstrap.url = "github:IntersectMBO/cardano-node/8.9.0";
    # cardano-node-bootstrap.url = "path:/home/jlotoski/work/iohk/cardano-node-wt/8.9.0";

    # For cardano-node service local debug:
    cardano-node-bootstrap-service = {
      url = "github:IntersectMBO/cardano-node/8.9.0";
      # url = "path:/home/jlotoski/work/iohk/cardano-node-wt/8.9.0";
      flake = false;
    };

    # For HD testing
    iohk-nix-legacy.url = "github:input-output-hk/iohk-nix/migrate-to-play-legacy";

    # Voltaire backend swagger ui for private chain deployment
    govtool.url = "github:IntersectMBO/govtool/flake";
  };

  outputs = inputs: let
    inherit (inputs.nixpkgs.lib) mkOption types;
    inherit (inputs.cardano-parts.lib) recursiveImports;
  in
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      imports =
        recursiveImports [
          ./flake
          ./perSystem
        ]
        ++ [
          inputs.cardano-parts.flakeModules.aws
          inputs.cardano-parts.flakeModules.cluster
          inputs.cardano-parts.flakeModules.entrypoints
          inputs.cardano-parts.flakeModules.jobs
          inputs.cardano-parts.flakeModules.lib
          inputs.cardano-parts.flakeModules.pkgs
          inputs.cardano-parts.flakeModules.process-compose
          inputs.cardano-parts.flakeModules.shell
          {options.flake.opentofu = mkOption {type = types.attrs;};}
        ];
      systems = ["x86_64-linux"];
      debug = true;
    };

  nixConfig = {
    extra-substituters = ["https://cache.iog.io"];
    extra-trusted-public-keys = ["hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="];
    allow-import-from-derivation = true;
  };
}
