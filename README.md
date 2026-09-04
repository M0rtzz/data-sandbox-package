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
the script rejects root, foreign-owned source directories, dirty worktrees, and commits that
have not been pushed to the configured upstream branch. The checkout may be located under
`/data/xzh` when it is owned by xzh; isolation is enforced with private paths, ports, labels,
containers, networks, databases, certificates, snapshots and backups.

The default branch is `develop/<system-user>`. The first start prompts for a private administrator
password and stores all runtime state below the developer's own checkout. By default `up` builds
the current working tree, so a developer can test changes before creating a commit. Add
`--pushed-only` when checking that a release candidate is clean and synchronized with upstream.

For the current shared development baseline, both `secretpad` and `secretpad-frontend` use
`develop/xzh`. Run the isolated stack with an explicit developer name and branch:

```bash
./develop.sh up --name xzh --branch develop/xzh
./develop.sh status
./develop.sh logs --component secretpad
./develop.sh logs --component kuscia
./develop.sh restart
./develop.sh down
```

For the normal test-first workflow, edit code and start the private stack directly:

```bash
./develop.sh up --name xzh --branch develop/xzh
```

After the test passes, commit and push both repositories. The strict check is available for a
release verification:

```bash
./develop.sh up --name xzh --branch develop/xzh --pushed-only
```

Use explicit ports when multiple private stacks share one Docker host:

```bash
./develop.sh up \
  --port 20088 --gateway-port 20080 \
  --api-http-port 20082 --api-grpc-port 20083 \
  --internal-port 20081 --metrics-port 20084
```

`down` stops only containers carrying the current developer and workspace ownership labels. It
retains the private database and runtime data. Shared builds and deployments remain the sole
responsibility of the designated release operator.

## Local Hugging Face OpenAI API

`serve-hf-model.sh` loads a local Hugging Face weight directory with vLLM and exposes the standard
OpenAI `GET /v1/models` and `POST /v1/chat/completions` endpoints. The model directory must contain
`config.json`; no model is downloaded by the script. The default directory is
`/nas/Models/deepseek-llm-7b-chat`, and `--model` can override it.

```bash
./serve-hf-model.sh prepare

./serve-hf-model.sh start \
  --served-model-name deepseek-local \
  --cuda-visible-devices 0 \
  --host 0.0.0.0

./serve-hf-model.sh status
./serve-hf-model.sh test --message '用一句话介绍密态推理。'
./serve-hf-model.sh logs
./serve-hf-model.sh stop
```

To route local-weight deployments from the isolated CipherGPU stack to this runtime, recreate the
developer containers with the internal host URL. Keep `/v1` in the value because CipherGPU appends
`/chat/completions`:

```bash
export DATA_SANDBOX_DEV_VLLM_URL=http://host.docker.internal:39089/v1
./develop.sh up --name confidential-mvp --branch feat/confidential-compute-mvp
```

The direct vLLM API should remain local or firewall-restricted. It does not replace the platform's
authenticated and encrypted confidential-inference endpoint. Run `./serve-hf-model.sh --help` for
multi-GPU, context length, quantization, chat-template, API-key, and advanced vLLM options.

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
