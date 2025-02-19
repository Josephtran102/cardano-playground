set shell := ["bash", "-uc"]
set positional-arguments
alias terraform := tofu
alias tf := tofu

# Defaults
null := ""
stateDir := "STATEDIR=" + statePrefix / "$(basename $(git remote get-url origin))"
statePrefix := "~/.local/share"

# Common code
checkEnv := '''
  ENV="${1:-}"
  TESTNET_MAGIC="${2:-""}"

  if ! [[ "$ENV" =~ preprod$|preview$|private$|sanchonet$|shelley-qa$|demo$ ]]; then
    echo "Error: only node environments for demo, preprod, preview, private, sanchonet and shelley-qa are supported"
    exit 1
  fi

  if [ "$ENV" = "preprod" ]; then
    MAGIC="1"
  elif [ "$ENV" = "preview" ]; then
    MAGIC="2"
  elif [ "$ENV" = "shelley-qa" ]; then
    MAGIC="3"
  elif [ "$ENV" = "sanchonet" ]; then
    MAGIC="4"
  elif [ "$ENV" = "private" ]; then
    MAGIC="5"
  elif [ "$ENV" = "demo" ]; then
    MAGIC="42"
  fi

  # Allow a magic override if the just recipe optional var is provided
  if ! [ -z "${TESTNET_MAGIC:-}" ]; then
    MAGIC="$TESTNET_MAGIC"
  fi
'''

checkSshConfig := '''
  if not ('.ssh_config' | path exists) {
    print "Please run tofu first to create the .ssh_config file"
    exit 1
  }
'''

checkSshKey := '''
  if not ('.ssh_key' | path exists) {
    just save-bootstrap-ssh-key
  }
'''

sopsConfigSetup := '''
  # To support searching for sops config files from the target path rather than cwd up,
  # implement a userland solution until natively sops supported.
  #
  # This enables $NO_DEPLOY_DIR to be separate from the default $STAKE_POOL_DIR/no-deploy default location.
  # Ref: https://github.com/getsops/sops/issues/242#issuecomment-999809670
  function sops_config() {
    # Suppress xtrace on this fn as the return string is observed from the caller's output
    { SHOPTS="$-"; set +x; } 2> /dev/null

    FILE="$1"
    CONFIG_DIR=$(dirname "$(realpath "$FILE")")
    while ! [ -f "$CONFIG_DIR/.sops.yaml" ]; do
      if [ "$CONFIG_DIR" = "/" ]; then
        >&2 echo "error: no .sops.yaml file was found while walking the directory structure upwards from the target file: \"$FILE\""
        exit 1
      fi
      CONFIG_DIR=$(dirname "$CONFIG_DIR")
      done

    echo "$CONFIG_DIR/.sops.yaml"

    # Reset the xtrace option to its state prior to suppression
    [ -n "${SHOPTS//[^x]/}" ] && set -x
  }
'''

default:
  @just --list

apply *ARGS:
  colmena apply --verbose --on {{ARGS}}

apply-all *ARGS:
  colmena apply --verbose {{ARGS}}

build-book-prod:
  #!/usr/bin/env bash
  set -e
  cd docs
  ln -sf book-prod.toml book.toml
  cd -
  mdbook build docs/

build-book-staging:
  #!/usr/bin/env bash
  set -e
  cd docs
  ln -sf book-staging.toml book.toml
  cd -
  mdbook build docs/

build-machine MACHINE *ARGS:
  nix build -L .#nixosConfigurations.{{MACHINE}}.config.system.build.toplevel {{ARGS}}

build-machines *ARGS:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  for node in $nodes {just build-machine $node {{ARGS}}}

cf STACKNAME:
  #!/usr/bin/env nu
  mkdir cloudFormation
  nix eval --json '.#cloudFormation.{{STACKNAME}}' | from json | save --force 'cloudFormation/{{STACKNAME}}.json'
  rain deploy --debug --termination-protection --yes ./cloudFormation/{{STACKNAME}}.json

dbsync-psql HOSTNAME:
  #!/usr/bin/env bash
  just ssh {{HOSTNAME}} -t 'psql -U cexplorer cexplorer'

dbsync-pool-analyze HOSTNAME:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Pushing pool analysis sql command on {{HOSTNAME}}..."
  just scp scripts/dbsync-pool-perf.sql {{HOSTNAME}}:/tmp/

  echo
  echo "Executing pool analysis sql command on host {{HOSTNAME}}..."
  QUERY=$(just ssh {{HOSTNAME}} -t 'psql -P pager=off -xXU cexplorer cexplorer < /tmp/dbsync-pool-perf.sql')

  echo
  echo "Query output:"
  echo "$QUERY" | tail -n +2
  echo

  JSON=$(grep -oP '^faucet_pool_summary_json[[:space:]]+\| \K{.*$' <<< "$QUERY" | jq .)
  echo "$JSON"
  echo

  echo "Faucet pools to de-delegate are:"
  jq '.faucet_to_dedelegate' <<< "$JSON"
  echo

  echo "The string of indexes of faucet pools to de-delegate from the JSON above are:"
  jq '.faucet_to_dedelegate | to_entries | map(.key) | join(" ")' <<< "$JSON"
  echo

  MAX_SHIFT=$(grep -oP '^faucet_pool_to_dedelegate_shift_pct[[:space:]]+\| \K.*$' <<< "$QUERY")
  echo "The maximum percentage difference de-delegation of all these pools will make in chain density is: $MAX_SHIFT"

dbsync-create-faucet-stake-keys-table ENV HOSTNAME NUM_ACCOUNTS="500":
  #!/usr/bin/env bash
  set -euo pipefail
  TMPFILE="/tmp/create-faucet-stake-keys-table-{{ENV}}.sql"

  echo "Creating stake key sql injection command for environment {{ENV}} (this will take a minute)..."
  NOMENU=true \
  scripts/setup-delegation-accounts.py \
    --print-only \
    --wallet-mnemonic <(sops -d secrets/envs/{{ENV}}/utxo-keys/faucet.mnemonic) \
    --num-accounts {{NUM_ACCOUNTS}} \
    > "$TMPFILE"

  echo
  echo "Pushing stake key sql injection command for environment {{ENV}}..."
  just scp "$TMPFILE" {{HOSTNAME}}:"$TMPFILE"

  echo
  echo "Executing stake key sql injection command for environment {{ENV}}..."
  just ssh {{HOSTNAME}} -t "psql -XU cexplorer cexplorer < \"$TMPFILE\""

dedelegate-non-performing-pools ENV TESTNET_MAGIC=null *STAKE_KEY_INDEXES=null:
  #!/usr/bin/env bash
  set -euo pipefail
  {{checkEnv}}
  just set-default-cardano-env {{ENV}} "$MAGIC" "$PPID"

  echo
  echo "Starting de-delegation of the following stake key indexes: {{STAKE_KEY_INDEXES}}"
  for i in {{STAKE_KEY_INDEXES}}; do
    echo "De-delegating index $i"
    NOMENU=true scripts/restore-delegation-accounts.py \
      --testnet-magic {{TESTNET_MAGIC}} \
      --signing-key-file <(just sops-decrypt-binary secrets/envs/{{ENV}}/utxo-keys/rich-utxo.skey) \
      --wallet-mnemonic <(just sops-decrypt-binary secrets/envs/{{ENV}}/utxo-keys/faucet.mnemonic) \
      --delegation-index "$i"
    echo "Sleeping 2 minutes until $(date -d  @$(($(date +%s) + 120)))"
    sleep 120
    echo
    echo
  done

gen-payment-address-from-mnemonic MNEMONIC_FILE ADDRESS_OFFSET="0":
  cardano-address key from-recovery-phrase Shelley < {{MNEMONIC_FILE}} \
    | cardano-address key child 1852H/1815H/0H/0/{{ADDRESS_OFFSET}} \
    | cardano-address key public --with-chain-code \
    | cardano-address address payment --network-tag testnet

lint:
  deadnix -f
  statix check

list-machines:
  #!/usr/bin/env nu
  let nixosNodes = (do -i { ^nix eval --json '.#nixosConfigurations' --apply 'builtins.attrNames' } | complete)
  if $nixosNodes.exit_code != 0 {
     print "Nixos failed to evaluate the .#nixosConfigurations attribute."
     print "The output was:"
     print
     print $nixosNodes
     exit 1
  }

  {{checkSshConfig}}

  let sshNodes = (do -i { ^scj dump /dev/stdout -c .ssh_config } | complete)
  if $sshNodes.exit_code != 0 {
     print "Ssh-config-json failed to evaluate the .ssh_config file."
     print "The output was:"
     print
     print $sshNodes
     exit 1
  }

  let nixosNodesDfr = (
    let nodeList = ($nixosNodes.stdout | from json);
    let sanitizedList = (if ($nodeList | is-empty) {$nodeList | insert 0 ""} else {$nodeList});
    $sanitizedList
      | insert 0 "machine"
      | each {|i| [$i] | into record}
      | headers
      | each {|i| insert inNixosCfg {"yes"}}
      | dfr into-df
  )

  let sshNodesDfr = (
    let sshTable = ($sshNodes.stdout | from json | where ('HostName' in $it));
    if ($sshTable | is-empty) {
      [[Host IP]; ["" ""]] | dfr into-df
    }
    else {
      $sshTable | rename Host IP | dfr into-df
    }
  )

  (
    $nixosNodesDfr
      | dfr join -o $sshNodesDfr machine Host
      | dfr sort-by machine
      | dfr into-nu
      | update cells {|v| if $v == null {"Missing"} else {$v}}
      | where machine != ""
  )

mimir-alertmanager-bootstrap:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Enter the mimir admin username: "
  read -s MIMIR_USER
  echo

  echo "Enter the mimir admin token: "
  read -s MIMIR_TOKEN
  echo

  echo "Enter the mimir base monitoring fqdn without the HTTPS:// scheme: "
  read URL
  echo

  echo "Obtaining current mimir alertmanager config:"
  echo "-----------"
  mimirtool alertmanager get --address "https://$MIMIR_USER:$MIMIR_TOKEN@$URL/mimir" --id 1
  echo "-----------"

  echo
  echo "If the output between the dashed lines above is blank, you may need to preload an initial alertmanager ruleset"
  echo "for the mimir TF plugin to succeed, where the command to preload alertmanager is:"
  echo
  echo "mimirtool alertmanager load --address \"https://\$MIMIR_USER:\$MIMIR_TOKEN@$URL/mimir\" --id 1 alertmanager-bootstrap-config.yaml"
  echo
  echo "The contents of alertmanager-bootstrap-config.yaml can be:"
  echo
  echo "route:"
  echo "  group_wait: 0s"
  echo "  receiver: empty-receiver"
  echo "receivers:"
  echo "  - name: 'empty-receiver'"

query-tip-all:
  #!/usr/bin/env bash
  set -euo pipefail
  QUERIED=0
  for i in preprod preview private shelley-qa sanchonet demo; do
    TIP=$(just query-tip $i 2>&1) && {
      echo "Environment: $i"
      echo "$TIP"
      echo
      QUERIED=$((QUERIED + 1))
    }
  done
  [ "$QUERIED" = "0" ] && echo "No environments running." || true

query-tip ENV TESTNET_MAGIC=null:
  #!/usr/bin/env bash
  set -euo pipefail
  {{checkEnv}}
  {{stateDir}}
  cardano-cli query tip \
    --socket-path "$STATEDIR/node-{{ENV}}.socket" \
    --testnet-magic "$MAGIC"

save-bootstrap-ssh-key:
  #!/usr/bin/env nu
  print "Retrieving ssh key from tofu..."
  tofu workspace select -or-create cluster
  tofu init -reconfigure
  let tf = (tofu show -json | from json)
  let key = ($tf.values.root_module.resources | where type == tls_private_key and name == bootstrap)
  $key.values.private_key_openssh | save .ssh_key
  chmod 0600 .ssh_key

save-ssh-config:
  #!/usr/bin/env nu
  print "Retrieving ssh config from tofu..."
  nix build ".#opentofu.cluster" --out-link terraform.tf.json
  tofu init -reconfigure
  tofu workspace select -or-create cluster
  let tf = (tofu show -json | from json)
  let key = ($tf.values.root_module.resources | where type == local_file and name == ssh_config)
  $key.values.content | save --force .ssh_config
  chmod 0600 .ssh_config

set-default-cardano-env ENV TESTNET_MAGIC=null PPID=null:
  #!/usr/bin/env bash
  set -euo pipefail
  {{checkEnv}}
  {{stateDir}}
  # The log and socket file may not exist immediately upon node startup, so only check for the pid file
  if ! [ -s "$STATEDIR/node-{{ENV}}.pid" ]; then
    echo "Environment {{ENV}} does not appear to be running as $STATEDIR/node-{{ENV}}.pid does not exist"
    exit 1
  fi

  echo "Linking: $(ln -sfv "$STATEDIR/node-{{ENV}}.socket" node.socket)"
  echo "Linking: $(ln -sfv "$STATEDIR/node-{{ENV}}.log" node.log)"
  echo

  if [ -n "{{PPID}}" ]; then
    PARENTID="{{PPID}}"
  else
    PARENTID="$PPID"
  fi

  SHELLPID=$(cat /proc/$PARENTID/status | awk '/PPid/ {print $2}')
  DEFAULT_PATH=$(pwd)/node.socket

  echo "Updating shell env vars:"
  echo "  CARDANO_NODE_SOCKET_PATH=$DEFAULT_PATH"
  echo "  CARDANO_NODE_NETWORK_ID=$MAGIC"
  echo "  TESTNET_MAGIC=$MAGIC"

  SH=$(cat /proc/$SHELLPID/comm)
  if [[ "$SH" =~ bash$|zsh$ ]]; then
    # Modifying a parent shells env vars is generally not done
    # This is a hacky way to accomplish it in bash and zsh
    gdb -iex "set auto-load no" /proc/$SHELLPID/exe $SHELLPID <<END >/dev/null
      call (int) setenv("CARDANO_NODE_SOCKET_PATH", "$DEFAULT_PATH", 1)
      call (int) setenv("CARDANO_NODE_NETWORK_ID", "$MAGIC", 1)
      call (int) setenv("TESTNET_MAGIC", "$MAGIC", 1)
  END

    # Zsh env vars get updated, but the shell doesn't reflect this
    if [ "$SH" = "zsh" ]; then
      echo
      echo "Cardano env vars have been updated as seen by \`env\`, but zsh \`echo \$VAR\` will not reflect this."
      echo "To sync zsh shell vars with env vars:"
      echo "  source scripts/sync-env-vars.sh"
    fi
  else
    echo
    echo "Unexpected shell: $SH"
    echo "The following vars will need to be manually exported, or the equivalent operation for your shell:"
    echo "  export CARDANO_NODE_SOCKET_PATH=$DEFAULT_PATH"
    echo "  export CARDANO_NODE_NETWORK_ID=$MAGIC"
    echo "  export TESTNET_MAGIC=$MAGIC"
  fi

show-flake *ARGS:
  nix flake show --allow-import-from-derivation {{ARGS}}

show-nameservers:
  #!/usr/bin/env nu
  let domain = (nix eval --raw '.#cardano-parts.cluster.infra.aws.domain')
  let zones = (aws route53 list-hosted-zones-by-name | from json).HostedZones
  let id = ($zones | where Name == $"($domain).").Id.0
  let sets = (aws route53 list-resource-record-sets --hosted-zone-id $id | from json).ResourceRecordSets
  let ns = ($sets | where Type == "NS").ResourceRecords.0.Value
  print "Nameservers for the following hosted zone need to be added to the NS record of the delegating authority"
  print $"Nameservers for domain: ($domain) \(hosted zone id: ($id)) are:"
  print ($ns | to text)

sops-decrypt-binary FILE:
  #!/usr/bin/env bash
  set -euo pipefail
  {{sopsConfigSetup}}
  [ -n "${DEBUG:-}" ] && set -x

  # Default to stdout decrypted output.
  # This supports the common use case of obtaining decrypted state for cmd arg input while leaving the encrypted file intact on disk.
  sops --config "$(sops_config {{FILE}})" --input-type binary --output-type binary --decrypt {{FILE}}

sops-encrypt-binary FILE:
  #!/usr/bin/env bash
  set -euo pipefail
  {{sopsConfigSetup}}
  [ -n "${DEBUG:-}" ] && set -x

  # Default to in-place encrypted output.
  # This supports the common use case of first time encrypting plaintext state for public storage, ex: git repo commit.
  sops --config "$(sops_config {{FILE}})" --input-type binary --output-type binary --encrypt {{FILE}} | sponge {{FILE}}

scp *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  scp -o LogLevel=ERROR -F .ssh_config {{ARGS}}

ssh HOSTNAME *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  ssh -o LogLevel=ERROR -F .ssh_config {{HOSTNAME}} {{ARGS}}

ssh-bootstrap HOSTNAME *ARGS:
  #!/usr/bin/env nu
  {{checkSshConfig}}
  {{checkSshKey}}
  ssh -o LogLevel=ERROR -F .ssh_config -i .ssh_key {{HOSTNAME}} {{ARGS}}

ssh-for-all *ARGS:
  #!/usr/bin/env nu
  let nodes = (nix eval --json '.#nixosConfigurations' --apply builtins.attrNames | from json)
  $nodes | par-each {|node| just ssh -q $node {{ARGS}}}

ssh-for-each HOSTNAMES *ARGS:
  colmena exec --verbose --parallel 0 --on {{HOSTNAMES}} {{ARGS}}

ssh-list-ips HOSTNAME_REGEX_PATTERN:
  #!/usr/bin/env nu
  scj dump /dev/stdout -c .ssh_config | from json | default "" Host | default "" HostName | where Host =~ "{{HOSTNAME_REGEX_PATTERN}}" | get HostName | str join " "

ssh-list-names HOSTNAME_REGEX_PATTERN:
  #!/usr/bin/env nu
  scj dump /dev/stdout -c .ssh_config | from json | default "" Host | default "" HostName | where Host =~ "{{HOSTNAME_REGEX_PATTERN}}" | get Host | str join " "

start-demo:
  #!/usr/bin/env bash
  set -euo pipefail
  just stop-node demo

  {{stateDir}}

  echo "Cleaning state-demo..."
  if [ -d state-demo ]; then
    chmod -R +w state-demo
    rm -rf state-demo
  fi

  echo "Generating state-demo config..."

  export ENV=custom
  export GENESIS_DIR=state-demo
  export KEY_DIR=state-demo/envs/custom
  export DATA_DIR=state-demo/rundir

  export CARDANO_NODE_SOCKET_PATH="$STATEDIR/node-demo.socket"
  export TESTNET_MAGIC=42

  export NUM_GENESIS_KEYS=3
  export POOL_NAMES="sp-1 sp-2 sp-3"
  export STAKE_POOL_DIR=state-demo/groups/stake-pools

  export BULK_CREDS=state-demo/bulk.creds.all.json
  export PAYMENT_KEY=state-demo/envs/custom/utxo-keys/rich-utxo

  export UNSTABLE=true
  export UNSTABLE_LIB=true
  export USE_ENCRYPTION=true
  export USE_DECRYPTION=true
  export DEBUG=1

  SECURITY_PARAM=8 \
    SLOT_LENGTH=200 \
    START_TIME=$(date --utc +"%Y-%m-%dT%H:%M:%SZ" --date " now + 30 seconds") \
    nix run .#job-gen-custom-node-config

  nix run .#job-create-stake-pool-keys

  (
    jq -r '.[]' < <(just sops-decrypt-binary "$KEY_DIR"/delegate-keys/bulk.creds.bft.json)
    jq -r '.[]' < <(just sops-decrypt-binary "$STAKE_POOL_DIR"/no-deploy/bulk.creds.pools.json)
  ) | jq -s > "$BULK_CREDS"

  echo "Start cardano-node in the background. Run \"just stop\" to stop"
  NODE_CONFIG="$DATA_DIR/node-config.json" \
    NODE_TOPOLOGY="$DATA_DIR/topology.json" \
    SOCKET_PATH="$STATEDIR/node-demo.socket" \
    nohup setsid nix run .#run-cardano-node &> "$STATEDIR/node-demo.log" & echo $! > "$STATEDIR/node-demo.pid" &
  just set-default-cardano-env demo "" "$PPID"
  echo "Sleeping 30 seconds until $(date -d  @$(($(date +%s) + 30)))"
  sleep 30
  echo

  echo "Moving genesis utxo..."
  BYRON_SIGNING_KEY="$KEY_DIR"/utxo-keys/shelley.000.skey \
    ERA_CMD="alonzo" \
    nix run .#job-move-genesis-utxo
  echo "Sleeping 7 seconds until $(date -d  @$(($(date +%s) + 7)))"
  sleep 7
  echo

  echo "Registering stake pools..."
  POOL_RELAY=demo.local \
    POOL_RELAY_PORT=3001 \
    ERA_CMD="alonzo" \
    nix run .#job-register-stake-pools
  echo "Sleeping 7 seconds until $(date -d  @$(($(date +%s) + 7)))"
  sleep 7
  echo

  echo "Delegating rewards stake key..."
  ERA_CMD="alonzo" \
    nix run .#job-delegate-rewards-stake-key
  echo "Sleeping 320 seconds until $(date -d  @$(($(date +%s) + 320)))"
  sleep 320
  echo

  echo "Forking to babbage..."
  just query-tip demo
  MAJOR_VERSION=7 \
    ERA_CMD="alonzo" \
    nix run .#job-update-proposal-hard-fork
  echo "Sleeping 320 seconds until $(date -d  @$(($(date +%s) + 320)))"
  sleep 320
  echo

  echo "Forking to babbage (intra-era)..."
  just query-tip demo
  MAJOR_VERSION=8 \
    ERA_CMD="babbage" \
    nix run .#job-update-proposal-hard-fork
  echo "Sleeping 320 seconds until $(date -d  @$(($(date +%s) + 320)))"
  sleep 320
  echo

  echo "Forking to conway..."
  just query-tip demo
  MAJOR_VERSION=9 \
    ERA_CMD="babbage" \
    nix run .#job-update-proposal-hard-fork
  echo "Sleeping 320 seconds until $(date -d  @$(($(date +%s) + 320)))"
  sleep 320
  echo

  just query-tip demo
  echo "Finished sequence..."
  echo

start-node ENV:
  #!/usr/bin/env bash
  set -euo pipefail
  {{stateDir}}

  if ! [[ "{{ENV}}" =~ preprod$|preview$|private$|sanchonet$|shelley-qa ]]; then
    echo "Error: only node environments for preprod, preview, private, sanchonet and shelley-qa are supported for start-node recipe"
    exit 1
  fi

  # Stop any existing running node env for a clean restart
  just stop-node {{ENV}}
  echo "Starting cardano-node for envrionment {{ENV}}"

  if [[ "{{ENV}}" =~ preprod$|preview$ ]]; then
    UNSTABLE=false
    UNSTABLE_LIB=false
  else
    UNSTABLE=true
    UNSTABLE_LIB=true
  fi

  # Set required entrypoint vars and run node in a new nohup background session
  ENVIRONMENT="{{ENV}}" \
  UNSTABLE="$UNSTABLE" \
  UNSTABLE_LIB="$UNSTABLE_LIB" \
  DATA_DIR="$STATEDIR" \
  SOCKET_PATH="$STATEDIR/node-{{ENV}}.socket" \
  nohup setsid nix run .#run-cardano-node &> "$STATEDIR/node-{{ENV}}.log" & echo $! > "$STATEDIR/node-{{ENV}}.pid" &
  just set-default-cardano-env {{ENV}} "" "$PPID"

stop-all:
  #!/usr/bin/env bash
  set -euo pipefail
  for i in preprod preview private shelley-qa sanchonet demo; do
    just stop-node $i
  done

stop-node ENV:
  #!/usr/bin/env bash
  set -euo pipefail
  {{stateDir}}

  if [ -f "$STATEDIR/node-{{ENV}}.pid" ]; then
    echo "Stopping cardano-node for envrionment {{ENV}}"
    kill $(< "$STATEDIR/node-{{ENV}}.pid") 2> /dev/null || true
    rm -f "$STATEDIR/node-{{ENV}}.pid" "$STATEDIR/node-{{ENV}}.socket"
  fi

tofu *ARGS:
  #!/usr/bin/env bash
  set -euo pipefail
  IGREEN='\033[1;92m'
  IRED='\033[1;91m'
  NC='\033[0m'
  SOPS=("sops" "--input-type" "binary" "--output-type" "binary" "--decrypt")

  read -r -a ARGS <<< "{{ARGS}}"
  if [[ ${ARGS[0]} =~ cluster|grafana ]]; then
    WORKSPACE="${ARGS[0]}"
    ARGS=("${ARGS[@]:1}")
  else
    WORKSPACE="cluster"
  fi

  unset VAR_FILE
  if [ -s "secrets/tf/$WORKSPACE.tfvars" ]; then
    VAR_FILE="secrets/tf/$WORKSPACE.tfvars"
  fi

  echo -e "Running tofu in the ${IGREEN}$WORKSPACE${NC} workspace..."
  rm --force terraform.tf.json
  nix build ".#opentofu.$WORKSPACE" --out-link terraform.tf.json

  tofu init -reconfigure
  tofu workspace select -or-create "$WORKSPACE"
  tofu ${ARGS[@]} ${VAR_FILE:+-var-file=<("${SOPS[@]}" "$VAR_FILE")}
