# Data Sandbox MVP Package

This directory is an independent build and upgrade package for the Data Sandbox MVP. It does
not read files from or execute scripts in `secretflow-allinone-package`.

It upgrades an existing SecretPad/Kuscia all-in-one deployment by replacing only the SecretPad
container while retaining its database, configuration, certificates, data, network and Kuscia
service name. The previous container is renamed and retained for rollback.

It also contains its own local P2P test-partner deployment tool. It does not invoke, source, or
read any script from `secretflow-allinone-package`.

## Build

```bash
./build.sh
```

The build uses the local sibling repositories `../secretpad` and `../secretpad-frontend`, creates
`data-sandbox-secretpad:mvp`, and writes the jar to `artifacts/`.

## Install or upgrade

```bash
cp data-sandbox.env.example data-sandbox.env
# The example matches the current autonomy/alice deployment. If the topology changes,
# update SOURCE_SECRETPAD_CONTAINER and SECRETPAD_CONTAINER first.
./install.sh
```

The required NAS locations are fixed by default:

- snapshots: `/nas/Misc/data-sandbox/snapshots`
- backups: `/nas/Misc/data-sandbox/backups`

Set `DATA_SANDBOX_KUSCIA_ENABLED=true` only after a usable IDE/Jupyter Kuscia AppImage has been
registered. GPU fields in this MVP are inventory and quota metadata only.

## Local P2P test partner

Use this only to create a second local test participant for joint projects. The partner runtime
stores configuration, business data and logs under the selected NAS directory. Kuscia's
containerd, K3s, image runtime, and the live SecretPad SQLite/H2 databases are stored under
`/data/xzh/Workspaces/Misc/data-sandbox/.runtime`, because overlayfs cannot run on the NAS/CIFS
filesystem and SQLite cannot provide reliable file locking there. It does not create a Docker
volume or runtime directory under `/root`.

```bash
sudo bash install.sh autonomy \
  -n bob -s 9088 -p 28080 -k 28082 -g 28083 \
  -q 23081 -x 23084 -i DataSandbox-B -u adminb -w 'replace-with-a-strong-password'
```

After creation, obtain the real Bob authentication code from this package:

```bash
./partner-node.sh auth-code bob
```

In the Alice console, open `合作节点` -> `添加合作节点`, paste this code into `节点认证码`,
select `识别解析`, select `alice` as the local node, and confirm. Do not manually invent the
certificate, institution ID, or node ID. The required Alice endpoint is
`https://root-kuscia-autonomy-alice:1080`; the generated Bob endpoint is
`https://data-sandbox-kuscia-autonomy-bob:1080`.

```bash
./partner-node.sh status bob
./partner-node.sh logs bob
./partner-node.sh remove bob
```

If the partner console was resumed after an interrupted installation, reset its administrator
password without recreating Kuscia or deleting partner data. The command prompts twice when `-w`
is omitted and preserves Bob's current console port and institution name:

```bash
sudo ./partner-node.sh reset-password bob
```

To resume a console whose container was removed, use the same command with `resume`; it also
requires the real administrator password and never uses a placeholder password:

```bash
sudo ./partner-node.sh resume bob
```

## Isolated developer system

`develop.sh` builds and runs a private Kuscia and SecretPad stack for a developer. It does not
read `data-sandbox.env`, invoke `install.sh`, or reuse the shared Alice/Bob containers, ports,
database, certificates, snapshots, or backups. Run it from a checkout owned by the developer;
the script rejects root, foreign-owned source directories and `/data/xzh` paths.

### Two testing modes (branch-based)

`--branch <name>` selects the branch to test (default `develop/<system-user>`). By default `up`
builds the **current working tree** on that branch, so a developer can test changes **before
creating a commit**; the working tree may be dirty. Test directly on the branch, then commit and
push afterwards. Add `--pushed-only` to check that a release candidate is clean and synchronized
with its upstream branch before building.

```bash
./develop.sh up                      # working-tree mode on develop/<system-user>
./develop.sh up --branch develop/zgz --name zgz
./develop.sh up --pushed-only        # strict: clean + pushed + upstream-synced only
./develop.sh status
./develop.sh logs --component secretpad
./develop.sh logs --component kuscia
./develop.sh restart
./develop.sh down
```

`up` also verifies that a rootful Docker daemon is reachable (sandbox containers can only truly
start under a daemon with full cgroup control). If rootful access is unavailable it stops with an
explicit message; you can fall back to a specific daemon with `DOCKER_HOST=unix:///.../docker.sock`.

Use explicit ports when multiple private stacks share one Docker host:

```bash
./develop.sh up \
  --port 18088 --gateway-port 18080 \
  --api-http-port 18082 --api-grpc-port 18083 \
  --internal-port 13081 --metrics-port 13084
```

`down` stops only containers carrying the current developer and workspace ownership labels. It
retains the private database and runtime data. Shared builds and deployments remain the sole
responsibility of the designated release operator.

## Operations

```bash
./ops.sh status
./ops.sh logs
./ops.sh diagnose
./ops.sh restore <backup-id>
./ops.sh rollback
```

`restore` validates that the API has staged `restore-pending.sqlite`, stops SecretPad, retains a
timestamped copy of the current database, switches the database file and starts SecretPad again.

## Security

The generated runtime env file is mode `0600`. Administrator credentials are never printed by
the package or SecretPad startup. Rotate any credential that has appeared in historical logs.

Portions of the shell structure were adapted from SecretFlow's all-in-one package and retain the
Apache-2.0 copyright/license notice.
