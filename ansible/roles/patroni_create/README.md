# Patroni PostgreSQL cluster bootstrap and recreation

The `patroni_create` role provisions a PostgreSQL 18 high-availability cluster
on the hosts in the configured inventory group. It is called by
`ansible/playbooks/create_cluster.yml`.

This role is intended for bootstrapping a cluster on new machines and for
destructively recreating a cluster during a planned maintenance window.
Configuration changes on a running cluster should be handled by a separate
role or a dedicated operating procedure.

> [!CAUTION]
> 🔴 **Cluster recreation is a deliberate and irreversible operational
> decision.** It must be explicitly reviewed and agreed with the application
> owners and the operators responsible for the database, storage, and backups
> before `patroni_create_wipe_existing_cluster` is enabled.

The role assumes full control of PostgreSQL and etcd data, dedicated data
disks, firewalld, managed volume entries, and the related systemd units.

## What the role configures

- Percona Distribution for PostgreSQL 18, Patroni, etcd, and pgBackRest;
- an OpenBao Agent authenticated with a client certificate;
- dedicated LUKS2/XFS volumes for PostgreSQL and etcd;
- automatic volume unlocking with keys retrieved from OpenBao;
- persistent mounts with validation of the expected mapper before services
  start;
- a firewalld zone with a default `DROP` policy and explicit allow rules;
- mTLS for etcd and the Patroni REST API, plus TLS for PostgreSQL;
- synchronous quorum replication and a required `softdog` watchdog;
- `pg_tde` with a global OpenBao provider and a default principal key;
- pgBackRest physical backups and WAL archiving to S3 or MinIO;
- logical dumps produced by `pg_back` and encrypted with an AGE public key;
- an example application database, the `app_user` and `dumper` roles, and the
  `public.ha_probe` table;
- post-deployment etcd and Patroni health checks;
- an optional Grafana Alloy agent that sends metrics through Prometheus Remote
  Write.

## Execution flow

1. Validate the supported operating system and every data-volume definition.
2. When wipe is explicitly enabled, stop backup timers and jobs, validate
   mounts, and remove the DCS entry and local PostgreSQL, WAL, and etcd data.
3. Install repositories and packages and prepare system services.
4. Import the internal CA into the system trust store.
5. Install the OpenBao Agent, authenticate with a certificate, and validate its
   token.
6. Verify access to every required OpenBao secret.
7. Validate block devices, create or open LUKS2 containers, create filesystems,
   and mount the volumes.
8. Remove managed volumes from `/etc/crypttab` and install the OpenBao-backed
   unlock service.
9. Configure firewalld, etcd, Patroni, PostgreSQL, and backups.
10. Start the cluster and wait for a leader, streaming replicas, and a
    synchronous or quorum standby.
11. Configure and verify `pg_tde` on the current leader.
12. Enable backup timers only after the `pg_tde` configuration succeeds.
13. Optionally install and configure Grafana Alloy.
14. In the playbook post-tasks, create or update the example application
    database on the leader.

## Requirements

### Deployment infrastructure

The deployment requires exactly three virtual machines or equivalent hosts
running Rocky Linux 9. Each machine is a member of all three cluster layers:

- PostgreSQL;
- Patroni;
- etcd.

The nodes should be dedicated to this cluster and must not host another
PostgreSQL or etcd workload. Each node requires:

- a separate dedicated disk for PostgreSQL data;
- a separate dedicated disk for etcd data;
- network connectivity to the other cluster members;
- hostnames and addresses that match the supplied certificates.

Two external services are also required:

- a working OpenBao server that stores cluster secrets and keys;
- S3-compatible storage with an existing bucket for physical backups, WAL
  archives, and logical dumps.

OpenBao and the S3 endpoint must be reachable from all three nodes. If Alloy
is enabled, the nodes must also be able to reach the configured Prometheus
Remote Write endpoint.

> [!IMPORTANT]
> **The complete deployment uses one shared certificate authority (CA).**
> Certificates used by OpenBao, etcd, Patroni, PostgreSQL, and the S3 endpoint
> must chain to this CA. The CA certificate is installed on every node as
> `/etc/pki/ca-trust/source/anchors/patroni-intra-ca.crt` and added to the
> system trust store. The CA private key remains outside the cluster nodes and
> is not used by the role.

### Ansible controller

- Ansible 2.20.1 or newer, as declared in the role metadata;
- collections listed in `ansible/collections/requirements.yml`;
- SSH access and privilege escalation on every target host;
- all required certificates and keys staged before execution.

Install the collections from the `ansible` directory:

```bash
ansible-galaxy collection install -r collections/requirements.yml
```

The role uses, among others:

- `ansible.posix`;
- `community.general`.

### Target hosts

- Rocky Linux 9 with systemd;
- access to the configured package repositories;
- support for LUKS2 and XFS;
- the ability to load the `softdog` module;
- dedicated disks matching `patroni_create_data_volumes`;
- access to the configured S3 bucket;
- HTTPS access to OpenBao.

The topology is designed for exactly three PostgreSQL/etcd nodes. Hostnames
and `ansible_host` addresses must match the supplied certificates.

## Inventory

```yaml
servers:
  children:
    psql:
      hosts:
        pg1:
          ansible_host: 192.168.172.101
        pg2:
          ansible_host: 192.168.172.102
        pg3:
          ansible_host: 192.168.172.103
```

Every member of `patroni_create_inventory_group` is used when generating:

- the initial etcd cluster;
- PostgreSQL replication rules;
- firewalld rules;
- the Patroni DCS endpoint list;
- LUKS key paths and certificate names.

## Critical inputs before running the playbook

> [!IMPORTANT]
> The role intentionally stops cluster services, manages the host firewall,
> removes its entries from `/etc/crypttab`, and may erase the block devices
> declared in `patroni_create_data_volumes`. Review all values for every host
> before running the playbook.

### Secrets required before provisioning

The following values must exist in OpenBao before the role starts:

- PostgreSQL passwords;
- LUKS keys;
- S3 credentials;
- the pgBackRest repository encryption passphrase;
- the AGE public key used for logical dumps.

The OpenBao Agent authenticates each node, writes a renewable token to
`/run/openbao-agent/token`, and the role verifies that every required field is
readable and non-empty. Secret values are not supplied as Ansible variables.

### OpenBao secret layout

The target layout uses a dedicated namespace and two KV v2 secrets engines:

| Secrets engine | Purpose |
| --- | --- |
| `patroni-secrets` | LUKS keys, PostgreSQL passwords, the pgBackRest passphrase, the AGE public key, and S3 credentials. |
| `pg-tde` | Principal keys managed directly by the `pg_tde` extension. Create the engine, but do not create key secrets manually. |

Default configuration:

```text
namespace: patroni
cert auth mount: patroni-cert
cluster secrets mount: patroni-secrets
pg_tde mount: pg-tde
cluster path: pg-cluster
```

Required paths and fields inside `patroni-secrets`:

| Secret path | Field | Contents |
| --- | --- | --- |
| `pg-cluster/nodes/pg1/luks/pgdata` | `key_b64` | Base64-encoded LUKS key for the PostgreSQL volume on `pg1`. |
| `pg-cluster/nodes/pg1/luks/etcd` | `key_b64` | Base64-encoded LUKS key for the etcd volume on `pg1`. |
| `pg-cluster/nodes/pg2/luks/pgdata` | `key_b64` | Base64-encoded LUKS key for the PostgreSQL volume on `pg2`. |
| `pg-cluster/nodes/pg2/luks/etcd` | `key_b64` | Base64-encoded LUKS key for the etcd volume on `pg2`. |
| `pg-cluster/nodes/pg3/luks/pgdata` | `key_b64` | Base64-encoded LUKS key for the PostgreSQL volume on `pg3`. |
| `pg-cluster/nodes/pg3/luks/etcd` | `key_b64` | Base64-encoded LUKS key for the etcd volume on `pg3`. |
| `pg-cluster/shared/pgbackrest` | `cipher_pass` | Shared pgBackRest repository encryption passphrase. |
| `pg-cluster/shared/pgdump` | `cipher_pub_key` | AGE public key used to encrypt logical dumps. |
| `pg-cluster/shared/s3` | `access_key`, `secret_key` | Credentials for S3-compatible storage. |
| `pg-cluster/shared/postgresql/postgres` | `password` | PostgreSQL superuser password. |
| `pg-cluster/shared/postgresql/replicator` | `password` | Streaming-replication password. |
| `pg-cluster/shared/postgresql/app` | `password` | Password for the `app_user` application role. |

> [!IMPORTANT]
> Each cluster node must have a separate LUKS secret for every encrypted
> volume. Paths follow
> `<cluster-path>/nodes/<inventory-hostname>/luks/<volume-name>`. The node name
> must exactly match the inventory name, and the volume name must match `name`
> in `patroni_create_data_volumes`. Names are case-sensitive.

The resulting structure is:

```text
namespace: patroni

patroni-secrets/
└── pg-cluster/
    ├── nodes/
    │   ├── pg1/luks/{pgdata,etcd}
    │   ├── pg2/luks/{pgdata,etcd}
    │   └── pg3/luks/{pgdata,etcd}
    └── shared/
        ├── pgbackrest
        ├── pgdump
        ├── s3
        └── postgresql/{postgres,replicator,app}

pg-tde/
└── keys created and maintained by pg_tde
```

Each node should be able to read only its own `nodes/<host>/luks/*` branch,
the shared `shared/*` secrets, and the required `pg-tde` engine paths. A node
should not be able to read the LUKS keys of another cluster member.

#### Example OpenBao policy

Minimum policy pattern for `pg1`:

```hcl
path "patroni-secrets/data/pg-cluster/nodes/pg1/luks/*" {
  capabilities = ["read"]
}

path "patroni-secrets/data/pg-cluster/shared/*" {
  capabilities = ["read"]
}

path "pg-tde/data/*" {
  capabilities = ["create", "read", "update", "list"]
}

path "pg-tde/metadata/*" {
  capabilities = ["read", "list"]
}

path "sys/mounts/pg-tde" {
  capabilities = ["read"]
}

path "sys/mounts/pg-tde/*" {
  capabilities = ["read"]
}

path "sys/internal/ui/mounts/pg-tde" {
  capabilities = ["read"]
}

path "sys/internal/ui/mounts/pg-tde/*" {
  capabilities = ["read"]
}

path "sys/capabilities-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
```

### Data volumes required by preflight

`patroni_create_data_volumes` is required on every cluster host. Preflight
checks that each item provides a non-empty `name`, `device`, and `path`, a
positive `gib`, and a non-empty `owner`. The LUKS stage then verifies that the
device exists, is a whole disk, and matches the declared size within a 2%
tolerance.

Use stable whole-disk paths under `/dev/disk/by-id/`. Do not use kernel-order
names such as `/dev/nvme0n2` or partitions ending in `-partN`.

Example host-specific configuration:

```yaml
patroni_create_data_volumes:
  - name: pgdata
    device: /dev/disk/by-id/<postgres-device-id>
    path: /var/lib/pgsql
    gib: 100
    owner: postgres
  - name: etcd
    device: /dev/disk/by-id/<etcd-device-id>
    path: /var/lib/etcd
    gib: 20
    owner: etcd
```

> [!CAUTION]
> If a device does not already contain LUKS, the role removes existing
> signatures, creates a LUKS2 container, and creates a new filesystem. A valid
> path and matching size do not prove that the disk contains no valuable data.
> Verify every device identifier against the infrastructure inventory.

### LUKS key material

LUKS keys are read from the node-specific paths documented above. The role
decodes `key_b64` directly into `cryptsetup`; it does not create a local key
file.

At boot, `patroni-unlock-volumes.service` waits for the OpenBao Agent token,
opens both mappings, and mounts the filesystems before etcd and Patroni start.
Renaming a node or volume requires creating the corresponding OpenBao path
before provisioning.

PostgreSQL and etcd volumes are deliberately removed from `/etc/crypttab` so
that systemd cannot start generated cryptsetup units and request an interactive
passphrase before OpenBao is available.

## Role variables

### Cluster and network

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_cluster_name` | `pg_cluster` | Patroni scope, PostgreSQL cluster name, and pgBackRest stanza name. |
| `patroni_create_pg_token` | `PostgreSQL_HA_Cluster` | Token used when forming the initial etcd cluster. |
| `patroni_create_inventory_group` | `psql` | Inventory group containing all Patroni and etcd nodes. |
| `patroni_create_management_cidr` | empty | Source CIDR allowed to use SSH and the optional Alloy UI. Use `/32` for one address. |
| `patroni_create_app_cidrs` | `[]` | CIDRs allowed to connect as `app_user` on TCP 5432. Matching `pg_hba` entries are generated. |
| `patroni_create_firewall_zone` | `patroni` | Managed firewalld zone with a `DROP` target, set as the default zone. |
| `patroni_create_firewall_ports` | `2379`, `2380`, `5432`, `8008` | TCP ports allowed between nodes: etcd client, etcd peer, PostgreSQL, and Patroni REST API. |

### Storage and encryption

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_volume_fstype` | `xfs` | Filesystem created inside each LUKS mapper. |
| `patroni_create_data_volumes` | See below | Dedicated volumes. Each item defines a stable `device`, mapper name, mount `path`, expected `gib`, and `owner`. |
| `patroni_create_wipe_existing_cluster` | `false` | When `true`, removes the DCS entry and PostgreSQL, local WAL, and etcd data and recreates encrypted volumes. It does not remove the remote backup repository. |

Default layout:

```yaml
patroni_create_volume_fstype: xfs
patroni_create_data_volumes:
  - name: pgdata
    device:
    path: /var/lib/pgsql
    gib: 10
    owner: postgres
  - name: etcd
    device:
    path: /var/lib/etcd
    gib: 5
    owner: etcd
```

Empty `device` values are deliberate. Each host must provide its own stable
`/dev/disk/by-id/...` path. The role does not discover a target disk by size.

For a new deployment, each device must be a dedicated whole disk. If it does
not contain LUKS, the role removes signatures, retrieves the node key from
OpenBao, creates LUKS2, opens the mapper, creates a filesystem, and mounts it.
A later run can reopen a container created with the same key. The role does
not migrate a container created with another key source.

### Application database

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_app_db_name` | `app` | Database created after the cluster becomes healthy. It is also used by logical dumps and access rules. |

The final SQL creates or updates:

- `app_user` with a password from `pg-cluster/shared/postgresql/app`;
- the local peer-authenticated `dumper` role;
- the application database;
- the `pg_tde` extension in the application database;
- `default_table_access_method=tde_heap`;
- `pg_tde.enforce_encryption=on`;
- the `public.ha_probe` table.

### S3, pgBackRest, and dumps

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_s3_endpoint` | `192.168.172.140` | S3-compatible hostname or address without a scheme. HTTPS is used. |
| `patroni_create_s3_port` | `9000` | TLS port of the S3 endpoint. |
| `patroni_create_s3_region` | `eu-central-1` | Region passed to pgBackRest and `pg_back`. |
| `patroni_create_s3_bucket_name` | `patroni-bucket` | Existing bucket for backups and dumps. The role does not create it. |
| `patroni_create_s3_prefix` | `/pgbackrest` | pgBackRest repository path inside the bucket. |
| `patroni_create_dump_prefix` | `pgdump` | Separate object prefix for encrypted logical dumps. |
| `patroni_create_dump_retention` | `3` | Minimum number of newest logical dumps retained by `pg_back`. |
| `patroni_create_dump_retention_days` | `7` | Age at which dumps become eligible for removal. |
| `patroni_create_on_boot_full_backup` | `3min` | Delay before the first full backup attempt after timer activation. |
| `patroni_create_interval_full_backup` | `30min` | Interval between full backup attempts. |
| `patroni_create_on_boot_incr_backup` | `5min` | Delay before the first incremental backup attempt. |
| `patroni_create_interval_incr_backup` | `2min` | Interval between incremental backup attempts. |
| `patroni_create_on_boot_dump` | `7min` | Delay before the first logical dump attempt. |
| `patroni_create_interval_dump` | `15min` | Interval between logical dump attempts. |

pgBackRest retains two full backups according to the generated configuration.
Timers run on every node, while `leader-gate` permits work only on the current
Patroni leader.

Every pgBackRest invocation retrieves the repository passphrase and S3
credentials through `pgbackrest-wrapper`. Every `pg_back` invocation retrieves
the AGE public key and S3 credentials through `pgback-wrapper`. Secrets are not
stored in `pgbackrest.conf`, `pg_back.conf`, or a local password file.

### OpenBao paths used by backups

| Variable | Default path | Purpose |
| --- | --- | --- |
| `patroni_create_bao_pgbackrest_path` | `pg-cluster/shared/pgbackrest` | Contains `cipher_pass` for physical backups and WAL archives. |
| `patroni_create_bao_pgdump_path` | `pg-cluster/shared/pgdump` | Contains `cipher_pub_key` for AGE-encrypted logical dumps. |
| `patroni_create_bao_s3_path` | `pg-cluster/shared/s3` | Contains `access_key` and `secret_key` for pgBackRest and `pg_back`. |

### OpenBao and `pg_tde`

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_bao_secret_namespace` | `patroni` | OpenBao namespace. |
| `patroni_create_bao_auth_path` | `patroni-cert` | Cert auth method mount. |
| `patroni_create_bao_address` | `https://192.168.172.160:8200` | OpenBao address. |
| `patroni_create_bao_token_path` | `/run/openbao-agent/token` | Token file created by the Agent. |
| `patroni_create_bao_secrets_mount` | `patroni-secrets` | KV v2 mount containing cluster secrets. |
| `patroni_create_bao_cluster_path` | `pg-cluster` | Root logical path for cluster secrets. |
| `patroni_create_bao_token_wait_timeout` | `120` | Time in seconds to wait for the Agent token. |
| `patroni_create_pg_tde_provider_name` | `openbao-patroni` | Name of the global `pg_tde` provider. |
| `patroni_create_pg_tde_mount_path` | `pg-tde` | OpenBao mount used by the provider. |
| `patroni_create_pg_tde_key_name` | `pg-cluster-default-key-v1` | Expected default principal key name. |

### Grafana Alloy

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_enable_alloy` | `true` | Installs, configures, and starts Alloy. |
| `patroni_create_enable_alloy_ui` | `false` | Exposes the Alloy HTTP UI on `0.0.0.0:12345`. |
| `patroni_create_alloy_logging_level` | `info` | Alloy log level. |
| `patroni_create_alloy_include_exporter_metrics` | `true` | Includes built-in Unix exporter metrics. |
| `patroni_create_alloy_scrape_interval` | `15s` | Local scrape interval. |
| `patroni_create_alloy_remote_write_url` | empty | Full Prometheus Remote Write endpoint URL. Required when Alloy is enabled. |

Alloy collects Unix system metrics, metrics about its own process, and the
state of selected systemd services. Remote Write is outbound traffic and does
not require an inbound port on a node. Port 12345 is allowed from
`patroni_create_management_cidr` only when the UI is enabled.

### Internal path variables

These values are defined in `vars/main.yml`, describe package layout, and are
not the normal role configuration interface.

| Variable | Value | Purpose |
| --- | --- | --- |
| `patroni_create_vars_etcd_data_dir` | `/var/lib/etcd` | etcd data directory and mountpoint. |
| `patroni_create_vars_etcd_ssl` | `/etc/etcd/ssl` | etcd certificate directory. |
| `patroni_create_vars_patroni_config_yaml` | `/etc/patroni/patroni.yml` | Patroni configuration file. |
| `patroni_create_vars_patroni_ssl` | `/etc/patroni/ssl` | Patroni REST certificate and key. |
| `patroni_create_vars_patroni_ssl_client` | `/etc/patroni/dcs-client` | Patroni client certificate for etcd. |
| `patroni_create_vars_patroni_bin` | `/usr/bin/patroni` | Patroni executable. |
| `patroni_create_vars_patroni_restart_svc_type` | `on-failure` | Patroni service restart policy. |
| `patroni_create_vars_postgres_main_dir` | `/var/lib/pgsql` | PostgreSQL parent directory and mountpoint. |
| `patroni_create_vars_postgres_data_dir` | `/var/lib/pgsql/18/data` | PostgreSQL data directory. |
| `patroni_create_vars_pgbackup_path` | `/var/lib/pgsql/archived` | Local archive removed during wipe. |
| `patroni_create_vars_postgres_socket` | `/var/run/postgresql` | PostgreSQL Unix socket directory. |
| `patroni_create_vars_postgres_bin` | `/usr/pgsql-18/bin` | PostgreSQL binary directory. |
| `patroni_create_vars_postgres_ssl` | `/var/lib/pgsql/18/ssl` | PostgreSQL server certificate directory. |
| `patroni_create_vars_pgbackrest_data_dir` | `/var/lib/pgbackrest` | pgBackRest data directory. |
| `patroni_create_vars_pgbackrest_log_dir` | `/var/log/pgbackrest` | pgBackRest log directory. |
| `patroni_create_vars_pgback_dumps_dir` | `/var/lib/pgsql/pg_back/dumps` | Local logical-dump working directory. |
| `patroni_create_vars_pgback_config_dir` | `/etc/pg_back` | `pg_back` configuration directory. |
| `patroni_create_vars_openbao_cert_dir` | `/etc/openbao-agent/tls` | OpenBao Agent client certificate and key. |
| `patroni_create_vars_openbao_config_dir` | `/etc/openbao-agent` | Agent configuration directory. |
| `patroni_create_vars_alloy_config_dir` | `/etc/alloy` | Alloy configuration directory. |

The shared CA is installed into the system trust store at:

```text
/etc/pki/ca-trust/source/anchors/patroni-intra-ca.crt
```

## Required role files

Certificates and private keys are supplied outside Git. A helper script can
generate test material, but production material must be staged before running
the playbook.

> [!WARNING]
> Test certificates are not suitable for production. In production, issue and
> deliver the complete certificate set through the organization's internal
> PKI, following its policies for identity validation, key protection,
> validity periods, renewal, revocation, and CA trust distribution.

> [!IMPORTANT]
> The role copies files whose names are derived from `inventory_hostname`. A
> missing, incorrectly named, expired, mismatched, or untrusted certificate
> stops deployment or prevents the OpenBao Agent, etcd, Patroni, PostgreSQL,
> health checks, or backups from working.

Files consumed by the role:

```text
files/
├── patroni-require-volume
└── certs/
    ├── ca/
    │   └── ca.crt
    ├── openbao/
    │   ├── ob-client-<inventory_hostname>.crt
    │   └── ob-client-<inventory_hostname>.key
    ├── etcd/
    │   ├── etcd-<inventory_hostname>.crt
    │   └── etcd-<inventory_hostname>.key
    ├── patroni/
    │   ├── patroni-<inventory_hostname>.crt
    │   └── patroni-<inventory_hostname>.key
    ├── dcs-client/
    │   ├── dcsclient-<inventory_hostname>.crt
    │   └── dcsclient-<inventory_hostname>.key
    └── postgres/
        ├── pgsrv-<inventory_hostname>.crt
        └── pgsrv-<inventory_hostname>.key
```

| Source | Destination and purpose |
| --- | --- |
| `certs/ca/ca.crt` | Installed as `/etc/pki/ca-trust/source/anchors/patroni-intra-ca.crt`; trusted by OpenBao, etcd, Patroni, PostgreSQL, and S3 clients. |
| `certs/openbao/ob-client-<host>.crt/.key` | Installed under `/etc/openbao-agent/tls`; node identity for OpenBao cert auth. |
| `certs/etcd/etcd-<host>.crt/.key` | Installed under `/etc/etcd/ssl`; etcd server and client mTLS. |
| `certs/patroni/patroni-<host>.crt/.key` | Installed under `/etc/patroni/ssl`; Patroni REST API and local leader checks. |
| `certs/dcs-client/dcsclient-<host>.crt/.key` | Installed under `/etc/patroni/dcs-client`; Patroni's client identity for etcd. |
| `certs/postgres/pgsrv-<host>.crt/.key` | Installed as `pgsrv.crt` and `pgsrv.key` under `/var/lib/pgsql/18/ssl`; PostgreSQL TLS. |
| `patroni-require-volume` | Installed as `/usr/local/sbin/patroni-require-volume`; validates the mountpoint and mapper before etcd and Patroni start. |

Certificate requirements:

- etcd certificates must support server and client use;
- the Patroni REST certificate must support server and client use;
- the DCS certificate must support client authentication;
- the PostgreSQL certificate must support server authentication;
- the OpenBao Agent certificate must meet the cert auth role requirements;
- server certificates must contain the inventory hostname and `ansible_host`;
- the certificate used by local REST checks must contain `127.0.0.1` in SAN;
- the PostgreSQL certificate should contain `DNS:localhost`;
- the S3 or MinIO certificate must chain to the CA trusted by the nodes.

The CA private key is not consumed by the role and must not be copied to target
hosts.

## Running the playbook

Run commands from the `ansible` directory.

### Create a new cluster

```bash
ansible-playbook -i inventory/servers.yml playbooks/create_cluster.yml --ask-vault-pass
```

With the default `patroni_create_wipe_existing_cluster: false`, the wipe block
is skipped. The role then:

1. validates the system, volumes, and required secrets;
2. installs packages and disables conflicting package-provided services;
3. configures the OpenBao Agent and validates its token;
4. validates devices, creates new LUKS2 containers or opens existing ones, and
   mounts filesystems;
5. installs the unlock service;
6. configures the firewall, etcd, Patroni, PostgreSQL, and backups;
7. starts the cluster and validates the leader and replicas;
8. configures `pg_tde`, starts timers, and optionally configures Alloy;
9. creates the application database on the leader.

> [!CAUTION]
> `patroni_create_wipe_existing_cluster: false` disables only the explicit
> cluster-data wipe. It does not make preparation of a new disk
> non-destructive. A device without LUKS is passed through `wipefs`,
> `luksFormat`, and filesystem creation. Existing LUKS is opened with the key
> from OpenBao and mounted without recreation. New deployments require
> dedicated disks whose contents may be destroyed.

### Recreate an existing cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE AND IRREVERSIBLE OPERATION**
>
> Setting `patroni_create_wipe_existing_cluster=true` explicitly requests the
> destruction of the local PostgreSQL cluster and complete local etcd state on
> every selected host. Run it only against the complete cluster inventory
> after agreeing on the data-loss boundary and recovery plan.

```bash
ansible-playbook -i inventory/servers.yml playbooks/create_cluster.yml \
  --ask-vault-pass \
  -e patroni_create_wipe_existing_cluster=true
```

Do not combine cluster recreation with `--limit` selecting only a subset of
Patroni/etcd members.

With wipe enabled, the playbook:

1. stops and disables full, incremental, and logical backup timers;
2. stops active backup jobs;
3. installs the volume verification helper;
4. verifies that every data path is a mountpoint backed by its expected
   `/dev/mapper/patroni-<name>`; an invalid state stops the wipe;
5. attempts to read the current cluster state and leader;
6. stops Patroni on every selected host;
7. attempts to remove the Patroni scope from DCS through `patronictl remove`;
8. removes the PostgreSQL data directory and local WAL archive;
9. stops etcd, unmounts its volume, and removes etcd data;
10. continues through normal provisioning, recreating LUKS containers, UUIDs,
    filesystems, and the cluster.

Wipe does not:

- restore PostgreSQL from a backup;
- delete physical backups from the remote pgBackRest repository;
- delete logical dump objects from S3 or MinIO;
- automatically rotate passwords, certificates, or backup secrets.

> [!CAUTION]
> 🔴 **VERIFY STORAGE BEFORE CONTINUING.** The role automatically validates
> mappers before deletion, but the operator should also verify mounts before a
> planned recreation:
>
> ```bash
> findmnt -no SOURCE --target /var/lib/pgsql
> findmnt -no SOURCE --target /var/lib/etcd
> ```
>
> Expected sources are `/dev/mapper/patroni-<postgres-volume-name>` and
> `/dev/mapper/patroni-<etcd-volume-name>`.

> [!CAUTION]
> 🔴 **REVIEW THE BACKUP REPOSITORY.** Recreating PostgreSQL produces a new
> system identifier. An existing pgBackRest stanza with the same cluster name
> and repository path may be incompatible with the new generation. Decide
> whether to retain the old repository under a separate prefix, archive it, or
> delete it manually. Preserve the historical `pgbackrest/cipher_pass` value
> and the AGE private keys required to decrypt retained dumps.

## Firewall behavior

The role creates the configured zone, applies a `DROP` target, and allows:

- SSH from `patroni_create_management_cidr`;
- cluster ports between all nodes;
- PostgreSQL from `patroni_create_app_cidrs`;
- optionally, the Alloy UI on TCP 12345 from
  `patroni_create_management_cidr`.

It then sets the managed zone as the host default. This default-deny policy is
intentional. An incorrect management CIDR can block SSH access.

## Systemd dependencies and service startup

Target startup flow:

```text
openbao-agent.service
        |
        v
patroni-unlock-volumes.service
        |
        v
etcd.service
        |
        v
percona-patroni.service
```

`patroni-unlock-volumes.service` waits for the token, retrieves LUKS keys,
opens mappers, and mounts filesystems. The etcd and Patroni units additionally
run `patroni-require-volume`, so they do not start against a directory on the
root filesystem instead of the expected mapper.

Patroni creates `/run/patroni` and `/run/postgresql` through
`RuntimeDirectory`, ensuring that the socket directory exists after a host
restart.

## `pg_tde` configuration

Patroni loads `pg_tde` through `shared_preload_libraries`. The role performs
configuration only on the current leader:

1. checks the extension in the `postgres` and `template1` databases;
2. creates missing extensions;
3. checks whether a global provider with the expected name exists;
4. registers OpenBao as the `vault-v2` provider when missing;
5. reads the current default principal key;
6. refuses to replace a different configured key;
7. attempts to select an existing key with the expected name;
8. creates and selects the key when it does not exist;
9. calls `pg_tde_verify_default_key()`.

The extension in `template1` allows new databases to inherit `pg_tde`. The
application database additionally receives:

```text
default_table_access_method = tde_heap
pg_tde.enforce_encryption = on
```

The role sets the `pg_tde` cipher to `aes_256`. In the current configuration,
`pg_tde.wal_encrypt` is `off`. Local WAL files remain protected by LUKS2, and
WAL stored in the repository is protected by pgBackRest encryption.

## Backup behavior

The role installs full backup, incremental backup, and logical dump timers on
every node. They are enabled only after the `pg_tde` provider and default key
have been configured and verified.

Each job queries the local Patroni REST API through mTLS. A replica exits
successfully without taking a backup. An unknown leadership state fails closed.

### pgBackRest

- creates physical backups and archives WAL;
- uses an S3 repository encrypted with AES-256-CBC;
- retrieves `cipher_pass`, `access_key`, and `secret_key` from OpenBao for
  every wrapper invocation;
- retains two full backups according to the generated configuration.

### `pg_back`

- dumps the application database in PostgreSQL custom format;
- connects through the local socket as `dumper` using peer mapping;
- encrypts the dump with the AGE public key retrieved from OpenBao;
- uploads the object to the configured S3 bucket;
- deletes the local file after a successful upload;
- removes old objects according to `patroni_create_dump_retention` and
  `patroni_create_dump_retention_days`.

The AGE private key is not stored on cluster nodes. It must be retained
separately because it is required to restore a dump.

## Behavior when OpenBao is unavailable

### Continues working until a service or host restart

- opened and mounted LUKS volumes;
- running PostgreSQL and etcd;
- existing database connections;
- Patroni using passwords loaded at startup;
- ongoing work on encrypted tables until `pg_tde` needs to retrieve material
  from the provider again.

### Stops working after OpenBao is lost

- new pgBackRest backups and archive operations that require secrets;
- new logical dumps;
- secret reads through `bao-read`;
- `pg_tde` operations that require contact with the provider;
- OpenBao Agent re-authentication after token loss or expiry.

### After a machine or service restart

- LUKS volumes cannot be opened automatically without the Agent and access to
  keys;
- etcd cannot start without the correct mount;
- Patroni/PostgreSQL cannot start without the volume and passwords retrieved
  by the wrapper;
- systemd dependencies retry the unlock service according to its configuration.

## Secret rotation procedures

The role creates or recreates a cluster from known inputs. It does not rotate
secrets on a running production cluster. Updating a KV value in OpenBao does
not update PostgreSQL roles, LUKS keyslots, existing backup encryption, or
application configuration.

For every rotation:

1. confirm cluster health and identify the current leader;
2. retain the previous secret in an approved location until testing completes;
3. suspend unrelated work and automatic switching when the procedure requires
   it;
4. change one component or one node at a time;
5. prepare rollback before removing the old value;
6. record which backups, dumps, or volumes require each historical key.

Do not place passwords directly in shell commands, CLI arguments, Ansible
variables, or SQL history. For PostgreSQL roles, use interactive `\password` in
a local `psql` session run as the operating-system `postgres` user.

### PostgreSQL `postgres` password

Path: `pg-cluster/shared/postgresql/postgres`, field `password`.

1. Generate and securely retain the new and previous values.
2. Connect locally to the leader:

   ```bash
   sudo -u postgres psql --no-psqlrc --dbname=postgres
   ```

3. Run:

   ```text
   \password postgres
   ```

4. Immediately update the OpenBao field. Treat the database and OpenBao
   changes as one operation; do not restart or fail over between them.
5. Restart Patroni on one replica at a time and wait for `running` and
   `streaming` after each restart.
6. Perform a controlled switchover to an updated node, restart the former
   leader, and verify the complete cluster.
7. Verify an administrative connection using the new password.

Rollback requires restoring the previous role password, restoring the OpenBao
value, and repeating the rolling Patroni restart.

### PostgreSQL `replicator` password

Path: `pg-cluster/shared/postgresql/replicator`, field `password`.

1. Confirm that every replica is in `streaming` state.
2. Run `\password replicator` on the leader.
3. Immediately update the OpenBao field.
4. Restart Patroni on replicas one at a time and wait for replication to
   resume.
5. Perform a controlled switchover to an updated replica and restart the former
   leader.
6. Verify member count, streaming state, synchronous standby, and lag.

The role change on the leader is replicated to the other members. Do not run
an independent `ALTER ROLE` on every replica.

### PostgreSQL `app_user` password

Path: `pg-cluster/shared/postgresql/app`, field `password`.

1. Stop or drain application traffic unless the application has a
   dual-credential rotation procedure.
2. Run `\password app_user` on the leader.
3. Update the OpenBao value and application configuration as one operation.
4. Reload the application and verify a TLS connection, read, and write.
5. Restore traffic only after successful validation.

Do not rerun the cluster creation role solely to rotate `app_user` on an
existing production cluster.

### S3 credentials

Path: `pg-cluster/shared/s3`, fields `access_key` and `secret_key`.

1. Create a second credential set while the old one remains active.
2. Grant the new credentials the minimum required bucket and prefix access.
3. Replace both OpenBao fields as one change.
4. On the leader, run `pgbackrest check`, a controlled backup, and a logical
   dump.
5. Verify uninterrupted WAL archiving.
6. Revoke the old credentials only after all checks succeed.

### pgBackRest repository passphrase

Path: `pg-cluster/shared/pgbackrest`, field `cipher_pass`.

Do not overwrite the passphrase of an existing repository. Its metadata,
backups, and WAL depend on the original value. The safest rotation creates a
new repository generation:

1. retain the old repository and passphrase;
2. stop timers and confirm that pgBackRest is not running;
3. allocate a new prefix or repository number;
4. set the new passphrase and configuration as one change;
5. create the stanza and immediately take a full backup;
6. perform a restore test;
7. resume timers and verify `archive-push` and `archive-get`;
8. retain the old passphrase for as long as it may be required for restore.

### Logical dump AGE key

Path: `pg-cluster/shared/pgdump`, field `cipher_pub_key`.

1. Stop the dump timer and confirm that no dump is running.
2. Retain the previous AGE private key and the object range that requires it.
3. Replace `cipher_pub_key` in OpenBao.
4. Start one logical dump manually on the current leader.
5. Download the object, decrypt it with the matching private key, and validate
   it using `pg_restore --list` or a controlled restore.
6. Resume the timer.

Existing objects are not re-encrypted. Retain each private key until all
matching dumps have expired or have been deliberately removed.

### LUKS2 keys

Paths are node-specific:
`pg-cluster/nodes/<node>/luks/<volume>`, field `key_b64`.

Rotate one volume on one node at a time:

1. confirm that the remaining nodes can maintain quorum and service;
2. generate a new key and store it temporarily under another field or path;
3. authenticate with the old key and add the new key to a free keyslot using
   `cryptsetup luksAddKey`;
4. validate it with `cryptsetup open --test-passphrase`;
5. only then replace `key_b64` in OpenBao;
6. reboot the node and verify unlock, mounts, etcd, Patroni, and membership;
7. only after the reboot succeeds, remove the old slot using
   `cryptsetup luksRemoveKey`;
8. repeat for the other volume and remaining nodes.

Never replace the only recoverable key before adding and testing the new one.
Wipe does not rotate a key; it destroys the old container and creates a new one.

### `pg_tde` principal key

Do not rotate the principal key while pgBackRest, a logical dump, or a restore
is running.

1. stop backup and dump timers and inspect running processes;
2. verify cluster health and availability of the `pg-tde` OpenBao store;
3. follow the rotation procedure approved for the installed `pg_tde` version;
4. verify reads and writes on encrypted tables and every member's state;
5. immediately take a new full pgBackRest backup and perform a restore test;
6. resume incremental backups and logical dumps only after successful testing.

Retain all OpenBao key versions needed to restore retained backups. Exact
commands depend on the extension version and provider configuration.

## Validation after deployment

The role waits for up to five minutes for exactly one leader, all other nodes
in `streaming` state, and at least one synchronous or quorum standby.

### Cluster

```bash
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
sudo systemctl status etcd percona-patroni --no-pager -l
```

### Volumes

```bash
findmnt /var/lib/pgsql
findmnt /var/lib/etcd
sudo cryptsetup status patroni-pgdata
sudo cryptsetup status patroni-etcd
```

### `pg_tde`

```bash
sudo -u postgres /usr/pgsql-18/bin/psql --dbname=app \
  --command="SHOW default_table_access_method;" \
  --command="SHOW pg_tde.enforce_encryption;"
```

Expected values:

```text
tde_heap
on
```

### Backups

```bash
sudo systemctl list-timers 'patroni-*'
sudo -u postgres /usr/local/libexec/patroni/pgbackrest-wrapper \
  --stanza=YOUR_CLUSTER_NAME info
```

### Alloy

```bash
sudo systemctl status alloy --no-pager -l
sudo journalctl -u alloy -n 100 --no-pager
curl -fsS http://127.0.0.1:12345/-/ready
```

The deployment procedure should also include controlled failover testing,
physical backup and logical dump restore tests, and service startup validation
after restarting each host.

## Limitations and assumptions

- the role is intended for new machines or complete cluster recreation;
- it does not migrate existing LUKS containers from local key files to OpenBao;
- it does not automatically rotate secrets;
- it does not remove remote backups during wipe;
- it does not automatically restore data;
- it assumes dedicated etcd instances on the same three nodes;
- it assumes an existing S3 bucket and valid credentials;
- it does not create an S3 user or policy;
- the AGE private key is managed outside the cluster nodes;
- for an existing `pg_tde` provider, it checks the name but does not compare
  stored parameters with the expected configuration;
- the dump timer is enabled before the post-task that creates the `dumper`
  role; on a very long playbook run, `OnBootSec` may trigger the first dump
  attempt before post-tasks finish;
- the local `pg_back` package is installed with GPG signature checking
  disabled;
- production backup intervals, retention, and disk sizes must be adjusted to
  the environment requirements.
