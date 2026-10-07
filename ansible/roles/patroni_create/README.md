# Patroni PostgreSQL cluster bootstrap and recreation

The `patroni` role provisions a PostgreSQL 18 high-availability cluster on the
hosts in the configured inventory group. It is called by
`ansible/playbooks/create_cluster.yml`.

This role is intended for bootstrapping a cluster on new machines and for
destructively recreating a cluster during a planned maintenance window.
Configuration changes on a running cluster are handled by a separate role.

> [!CAUTION]
> 🔴 **Cluster recreation is a deliberate and irreversible operational
> decision.** It must be explicitly reviewed and agreed with the application
> owners and the operators responsible for the database, storage, and backups
> before `patroni_create_wipe_existing_cluster` is enabled.

The role assumes full control of PostgreSQL and etcd data, dedicated data
disks, firewalld, its volume entries in `/etc/crypttab`, and the relevant
systemd units.

## What the role configures

- Percona Distribution for PostgreSQL 18, Patroni, etcd, and pgBackRest;
- dedicated LUKS2/XFS volumes for PostgreSQL and etcd;
- automatic volume unlocking and persistent mounts;
- a firewalld zone with a default `DROP` policy and explicit allow rules;
- mTLS for etcd and the Patroni REST API, plus TLS for PostgreSQL;
- synchronous quorum replication and a required `softdog` watchdog;
- pgBackRest backups and encrypted logical dumps in S3 or MinIO;
- an example application database, roles, and `public.ha_probe` table;
- post-deployment etcd and Patroni health checks.

## Execution flow

1. Validate required secrets, the operating system, and the structure of every
   data-volume definition.
2. When explicitly requested, irreversibly remove the existing DCS entry,
   PostgreSQL data, WAL archive, and etcd data.
3. Install packages and prepare services.
4. Validate the configured block devices, create fresh LUKS2 containers and
   filesystems, and mount the volumes.
5. Remove the managed volume entries from `/etc/crypttab` and install the
   OpenBao-backed unlock service.
6. Configure the firewall, etcd, Patroni, PostgreSQL, and pgBackRest.
7. Start the cluster and backup timers.
8. Wait for a leader and streaming synchronous replicas.
9. Create or update the example application database on the leader.

## Requirements

### Deployment infrastructure

A complete deployment requires four virtual machines or equivalent hosts:

- three dedicated Rocky Linux 9 virtual machines used only as the
  PostgreSQL, Patroni, and etcd cluster members;
- one additional machine providing an S3-compatible API, such as MinIO, to
  receive pgBackRest backups and encrypted logical dumps.

The three cluster machines must have no existing PostgreSQL or etcd workload.
Each cluster machine also needs separate dedicated data disks for PostgreSQL
and etcd. The object-storage machine is not a cluster member, but its HTTPS
endpoint and pre-created bucket must be reachable from all three cluster
machines.

Production deployments must additionally use certificates issued
and delivered by the organization's internal PKI, appropriately protected
secrets, production storage sizing, and an S3-compatible service that meets
the required availability and data-retention policy.

### Ansible controller

- Ansible 2.20.1 or newer, as declared in the role metadata.
- Collections listed in `ansible/collections/requirements.yml`.
- SSH access and privilege escalation on every target host.
- Required certificates and keys staged before execution.

Install the collections from the repository root:

```bash
cd ansible
ansible-galaxy collection install -r collections/requirements.yml
```

### Target hosts

- Rocky Linux 9 with systemd.
- Access to the configured package repositories.
- Support for LUKS2, XFS, and the `softdog` module.
- Dedicated disks matching `patroni_create_data_volumes`.
- Access to the configured S3 bucket.

The topology is designed for exactly three PostgreSQL/etcd nodes. These should
be fresh virtual machines dedicated to the cluster. Hostnames and
`ansible_host` addresses must match the supplied certificates.

## Inventory

```yaml
servers:
  children:
    psql:
      hosts:
        db-node-1:
          ansible_host: "<db-node-1-ip>"  # Replace with the first node address.
        db-node-2:
          ansible_host: "<db-node-2-ip>"  # Replace with the second node address.
        db-node-3:
          ansible_host: "<db-node-3-ip>"  # Replace with the third node address.
```

Every member of `patroni_create_inventory_group` is used when generating the etcd
initial cluster, PostgreSQL replication rules, firewall rules, and Patroni DCS
endpoint list.

## Critical inputs before running the playbook

> [!IMPORTANT]
> The role intentionally stops cluster services, controls the host firewall,
> removes its managed entries from `/etc/crypttab`, and may erase the block
> devices declared in `patroni_create_data_volumes`. Review all values below
> for every host before running the playbook.

### Secrets required before provisioning

PostgreSQL passwords, LUKS keys, S3 credentials, and backup encryption
passphrases must exist in OpenBao before the role runs. The OpenBao Agent
authenticates each node, and the role verifies that every required field is
readable and non-empty before configuring the cluster. These values are not
supplied as Ansible variables.

### OpenBao secret layout

The target OpenBao layout uses the dedicated namespace and two KV v2 secrets
engines:

| Secrets engine (mount) | Purpose |
| --- | --- |
| `patroni-secrets` | LUKS keys, backup and dump passphrases, object-storage credentials, and PostgreSQL passwords. |
| `pg-tde` | Database principal keys managed directly by the `pg_tde` extension. Create the empty KV v2 engine, but do not create its secrets manually. |

Create the following secret paths and fields:

| Secret path inside `patroni-secrets` | Field name | Contents |
| --- | --- | --- |
| `pg-cluster/nodes/pg1/luks/pgdata` | `key_b64` | Base64-encoded LUKS key for the PostgreSQL volume on `pg1`. |
| `pg-cluster/nodes/pg1/luks/etcd` | `key_b64` | Base64-encoded LUKS key for the etcd volume on `pg1`. |
| `pg-cluster/nodes/pg2/luks/pgdata` | `key_b64` | Base64-encoded LUKS key for the PostgreSQL volume on `pg2`. |
| `pg-cluster/nodes/pg2/luks/etcd` | `key_b64` | Base64-encoded LUKS key for the etcd volume on `pg2`. |
| `pg-cluster/nodes/pg3/luks/pgdata` | `key_b64` | Base64-encoded LUKS key for the PostgreSQL volume on `pg3`. |
| `pg-cluster/nodes/pg3/luks/etcd` | `key_b64` | Base64-encoded LUKS key for the etcd volume on `pg3`. |
| `pg-cluster/shared/pgbackrest` | `cipher_pass` | Shared pgBackRest repository encryption passphrase. |
| `pg-cluster/shared/pgdump` | `cipher_pass` | Independent logical-dump encryption passphrase. |
| `pg-cluster/shared/s3` | `access_key`, `secret_key` | Credentials for the S3-compatible backup storage. |
| `pg-cluster/shared/postgresql/postgres` | `password` | PostgreSQL superuser password. |
| `pg-cluster/shared/postgresql/replicator` | `password` | Streaming-replication password. |
| `pg-cluster/shared/postgresql/app_user` | `password` | Application-role password. |

> [!IMPORTANT]
> Each cluster node must have a separate LUKS secret for every encrypted
> volume. The paths follow the pattern
> `<cluster-secret-root>/nodes/<node-name>/luks/<volume-name>`. The node name
> must exactly match the name used for that node in the Ansible inventory, and
> the volume name must exactly match its identifier in the node's storage
> configuration. These names are case-sensitive. For example, node `pg1` and
> volume `pgdata` use `pg-cluster/nodes/pg1/luks/pgdata`.

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
        └── postgresql/{postgres,replicator,app_user}

pg-tde/
└── keys created and maintained by pg_tde
```
### Data volumes required by preflight

`patroni_create_data_volumes` is required on every cluster host. Preflight checks that
each item provides a non-empty `name`, `device`, `path`, positive `gib`, and
`owner`. The LUKS stage subsequently checks that `device` exists, is a whole
block disk, and matches the declared size within a 2% tolerance.

Use a stable whole-disk path under `/dev/disk/by-id/`, never a kernel-order name
such as `/dev/nvme0n2` and never a partition ending in `-partN`.

Example host-specific configuration:

```yaml
patroni_create_data_volumes:
  - name: pgdata
    device: /dev/disk/by-id/<postgres-device-id>  # Stable ID on this host.
    path: /var/lib/pgsql
    gib: 100  # Example only: replace with the actual whole-disk size in GiB.
    owner: postgres
  - name: etcd
    device: /dev/disk/by-id/<etcd-device-id>  # Stable ID on this host.
    path: /var/lib/etcd
    gib: 20  # Example only: replace with the actual whole-disk size in GiB.
    owner: etcd
```

> [!CAUTION]
> If a configured device is not already a LUKS container, the role removes its
> existing signatures, creates a new LUKS2 container, and creates a filesystem.
> A valid device path and matching size do not prove that the disk contains no
> valuable data. Verify every device ID against the infrastructure inventory.

### LUKS key material

LUKS keys are read from the node-specific OpenBao paths documented above. The
role decodes `key_b64` directly into `cryptsetup`; it does not create a local
key file. At boot, `patroni-unlock-volumes.service` waits for the OpenBao Agent
token, opens both mappings and mounts the filesystems before etcd and Patroni
start. Renaming a node or volume requires creating the corresponding OpenBao
path before provisioning.

## Role variables

### Cluster and network

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_cluster_name` | `pg_cluster` | Patroni scope, PostgreSQL cluster name, and pgBackRest stanza name. |
| `patroni_create_pg_token` | `PostgreSQL_HA_Cluster` | etcd token used when forming the initial cluster. |
| `patroni_create_inventory_group` | `psql` | Inventory group containing all Patroni and etcd nodes. |
| `patroni_create_management_cidr` | empty | IPv4 source allowed to use SSH. Set it before deployment; use `/32` for one address. |
| `patroni_create_app_cidrs` | `[]` | IPv4 CIDRs allowed to connect as `app_user` on TCP 5432. Corresponding `pg_hba` entries are generated. |
| `patroni_create_firewall_zone` | `patroni` | Managed firewalld zone. The role gives it a `DROP` target and makes it the default zone. |
| `patroni_create_firewall_ports` | `2379`, `2380`, `5432`, `8008` | TCP ports allowed between cluster nodes: etcd client, etcd peer, PostgreSQL, and Patroni REST API. |

### Storage and encryption

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_volume_fstype` | `xfs` | Filesystem created inside each LUKS mapper. It is passed to `mkfs.<value>`. |
| `patroni_create_data_volumes` | See below | Dedicated volumes. Each item defines a stable whole-disk `device`, mapper `name`, mount `path`, expected size in `gib`, and filesystem `owner`. Mapper names are generated as `patroni-<name>`. Override this list per host. |
| `patroni_create_wipe_existing_cluster` | `false` | When `true`, removes the DCS entry and PostgreSQL, WAL archive, and etcd data. It does not remove the remote backup repository. |

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

The empty device defaults are deliberate: every host must provide its own
stable `/dev/disk/by-id/...` paths. The role does not discover a target disk by
size. It uses the configured device and treats the declared size as an
additional validation constraint.

For a new deployment, each configured device must be a dedicated whole disk
that does not already contain LUKS. The role removes existing signatures,
retrieves the node key from OpenBao, creates a new LUKS2 container, opens the
mapper, creates a new filesystem, and mounts it. A later run can reopen a LUKS
container created with the same OpenBao key. This workflow does not migrate a
container created with another key source.

The PostgreSQL and etcd volumes are deliberately absent from `/etc/crypttab`.
Otherwise systemd can start its generated cryptsetup units and request an
interactive passphrase before OpenBao is available. The dedicated OpenBao
unlock service retrieves each key after networking and Agent authentication,
then opens and mounts the volumes. Entries unrelated to this role remain
unchanged.

### Application database

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_app_db_name` | `app` | Database created after the cluster is healthy. Also used by the logical dump job and access rules. Use a valid PostgreSQL identifier. |

The bootstrap SQL creates or updates `app_user`, the local peer-authenticated
`dumper` role, the application database, and `public.ha_probe`. The `app_user`
password is read from `pg-cluster/shared/postgresql/app_user` in OpenBao.

### S3, pgBackRest, and dumps

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_create_s3_endpoint` | Environment-specific value in `defaults/main.yml`; override it | Hostname or address of the deployment's S3-compatible endpoint without a scheme. HTTPS is used. |
| `patroni_create_s3_port` | `9000` | TLS port of the configured S3-compatible endpoint. |
| `patroni_create_s3_region` | `eu-central-1` | Region passed to pgBackRest and boto3. |
| `patroni_create_s3_bucket_name` | `patroni-bucket` | Existing bucket for backups and dumps. The role does not create it. |
| `patroni_create_s3_prefix` | `/pgbackrest` | pgBackRest repository path inside the bucket. |
| `patroni_create_dump_prefix` | `pgdump` | Independent object prefix for encrypted logical dumps. |
| `patroni_create_dump_retention` | `3` | Number of newest logical dumps retained under the dump prefix. |
| `patroni_create_on_boot_full_backup` | `3min` | Delay before the first full backup attempt after timer activation. |
| `patroni_create_interval_full_backup` | `30min` | Interval between full backup attempts. |
| `patroni_create_on_boot_incr_backup` | `5min` | Delay before the first incremental backup attempt. |
| `patroni_create_interval_incr_backup` | `2min` | Interval between incremental backup attempts. |
| `patroni_create_on_boot_dump` | `7min` | Delay before the first logical dump attempt. |
| `patroni_create_interval_dump` | `15min` | Interval between logical dump attempts. |

pgBackRest retains two full backups according to the generated configuration.
Timers run on every node, while `leader-gate` permits backup work only on the
current Patroni leader. Each pgBackRest invocation reads the repository
passphrase and S3 credentials from OpenBao through `pgbackrest-wrapper`.
Logical dumps independently read their encryption passphrase and S3
credentials from OpenBao when `run-dump` starts. No backup passphrase or S3
credential is written to the generated pgBackRest configuration or a local
passphrase file.

### OpenBao paths used by backups

| Variable | Default path | Purpose |
| --- | --- | --- |
| `patroni_create_bao_pgbackrest_path` | `pg-cluster/shared/pgbackrest` | Contains the `cipher_pass` field for physical backups and WAL archives. |
| `patroni_create_bao_pgdump_path` | `pg-cluster/shared/pgdump` | Contains the independent `cipher_pass` field for logical dumps. |
| `patroni_create_bao_s3_path` | `pg-cluster/shared/s3` | Contains `access_key` and `secret_key` for pgBackRest and logical dumps. |

### Internal path variables

These values are defined in `vars/main.yml` and describe the package layout.
Role vars have high precedence and are not the normal configuration interface.

| Variable | Value | Purpose |
| --- | --- | --- |
| `patroni_create_vars_ca_cert_dir` | `/etc/pki/patroni` | Installed CA directory. |
| `patroni_create_vars_etcd_data_dir` | `/var/lib/etcd` | etcd data directory and mountpoint. |
| `patroni_create_vars_etcd_ssl` | `/etc/etcd/ssl` | etcd certificate directory. |
| `patroni_create_vars_patroni_config_yaml` | `/etc/patroni/patroni.yml` | Patroni configuration file. |
| `patroni_create_vars_patroni_ssl` | `/etc/patroni/ssl` | Patroni REST certificate directory. |
| `patroni_create_vars_patroni_ssl_client` | `/etc/patroni/dcs-client` | Patroni etcd client certificate directory. |
| `patroni_create_vars_patroni_bin` | `/usr/bin/patroni` | Patroni executable. |
| `patroni_create_vars_patroni_restart_svc_type` | `on-failure` | Patroni systemd restart policy. |
| `patroni_create_vars_postgres_main_dir` | `/var/lib/pgsql` | PostgreSQL parent directory and mountpoint. |
| `patroni_create_vars_postgres_data_dir` | `/var/lib/pgsql/18/data` | PostgreSQL data directory. |
| `patroni_create_vars_pgbackup_path` | `/var/lib/pgsql/archived` | Local archive directory removed during recreation. |
| `patroni_create_vars_postgres_socket` | `/var/run/postgresql` | PostgreSQL Unix socket directory. |
| `patroni_create_vars_postgres_bin` | `/usr/pgsql-18/bin` | PostgreSQL binary directory. |
| `patroni_create_vars_postgres_ssl` | `/var/lib/pgsql/18/ssl` | PostgreSQL server certificate directory. |
| `patroni_create_vars_pgbackrest_data_dir` | `/var/lib/pgbackrest` | pgBackRest data directory. |
| `patroni_create_vars_pgbackrest_log_dir` | `/var/log/pgbackrest` | pgBackRest log directory. |

## Required role files

Certificates and private keys are supplied outside Git. A separate script can
generate them for test environments; production material must be staged before
running the playbook.

> [!WARNING]
> The certificate-generation script does not produce certificate material
> suitable for a production deployment. For production, issue and deliver the
> complete certificate set through the organization's internal PKI, following
> its policies for identity validation, key protection, validity periods,
> renewal, revocation, and CA trust distribution.

> [!IMPORTANT]
> The role copies files by names derived from `inventory_hostname`. A missing,
> incorrectly named, expired, mismatched, or untrusted certificate stops the
> deployment or prevents etcd, Patroni, PostgreSQL, health checks, or backups
> from working. Prepare the complete file set for every cluster member before
> execution.

Only the following files under `ansible/playbooks/roles/patroni/files/` are
consumed by the role:

```text
files/
├── patroni-require-volume
└── certs/
    ├── ca/
    │   └── ca.crt
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

Every host-specific certificate directory therefore needs a matching pair for
each of the three inventory hostnames, for example `db-node-1`, `db-node-2`,
and `db-node-3`.

| Location | Installed destination and purpose |
| --- | --- |
| `certs/ca/ca.crt` | Installed as `/etc/pki/patroni/ca.crt`. It is the trust anchor for etcd, Patroni REST, PostgreSQL TLS, and the configured S3 or MinIO endpoint. |
| `certs/etcd/etcd-<host>.crt/.key` | Installed under `/etc/etcd/ssl`. etcd uses the pair for encrypted and mutually authenticated peer and client traffic. |
| `certs/patroni/patroni-<host>.crt/.key` | Installed under `/etc/patroni/ssl`. Patroni serves its REST API with this pair; local leader checks and Ansible health checks also authenticate with it. |
| `certs/dcs-client/dcsclient-<host>.crt/.key` | Installed under `/etc/patroni/dcs-client`. Patroni uses it as a client identity when connecting to etcd. |
| `certs/postgres/pgsrv-<host>.crt/.key` | Installed as `pgsrv.crt` and `pgsrv.key` under `/var/lib/pgsql/18/ssl`. PostgreSQL uses the pair for TLS client and replication connections. |
| `patroni-require-volume` | Installed as `/usr/local/sbin/patroni-require-volume`. The etcd and Patroni systemd units call it before startup to ensure their data path is a mountpoint backed by the expected LUKS mapper. |

Certificate requirements:

- etcd certificates require server and client authentication usage;
- Patroni REST certificates require server and client authentication usage;
- DCS client certificates require client authentication usage;
- PostgreSQL certificates require server authentication usage;
- server certificates must contain the inventory hostname and its
  `ansible_host` address;
- certificates used through `127.0.0.1` by local health checks must include
  that address in their subject alternative names;
- PostgreSQL server certificates must include `DNS:localhost`, because Patroni
  verifies its local replication connection using the `localhost` hostname;
- the certificate presented by S3 or MinIO must chain to `ca.crt`.

The CA private key is not consumed by the role and must not be copied to target
hosts.

## Running the playbook

Run from the `ansible` directory.

### Create a new cluster

```bash
ansible-playbook playbooks/create_cluster.yml --ask-vault-pass
```

With the default `patroni_create_wipe_existing_cluster: false`, the wipe block is
skipped. The role then:

1. validates the operating system, required secrets, and volume definitions;
2. installs the required repositories and packages and disables conflicting
   package-provided services;
3. validates every configured device against its declared type and size;
4. retrieves each node-specific key from OpenBao, creates a new LUKS2 container
   and configured filesystem, then opens and mounts the mapper;
5. removes the managed volumes from `/etc/crypttab` and installs the
   OpenBao-backed unlock service;
6. configures the firewall, etcd, Patroni, PostgreSQL, and pgBackRest;
7. starts the cluster, waits for one leader and streaming synchronous replicas,
   and creates the application database on the leader.

> [!CAUTION]
> `patroni_create_wipe_existing_cluster: false` disables only the explicit cluster-data
> wipe. It does not make storage preparation non-destructive. A configured
> device without LUKS is passed through `wipefs`, `luksFormat`, and filesystem
> creation. An existing LUKS device is opened with the matching key from
> OpenBao and its existing filesystem is mounted without recreation. Setting
> `patroni_create_wipe_existing_cluster: true` recreates the LUKS container and
> filesystem. New deployments require dedicated disks whose contents may be
> destroyed.

### Recreate an existing cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE AND IRREVERSIBLE OPERATION**
>
> Setting `patroni_create_wipe_existing_cluster=true` is an explicit request to
> destroy the local PostgreSQL cluster and the complete local etcd state on
> every selected host. Use this option only when the application is not
> required to remain available and there is an agreed need to destroy and
> rebuild the cluster. The decision must be reviewed with the application and
> database owners, including the expected data-loss boundary and backup
> recovery plan. Run it against the complete cluster inventory.

```bash
ansible-playbook playbooks/create_cluster.yml \
  --ask-vault-pass \
  -e patroni_create_wipe_existing_cluster=true
```

Do not combine cluster recreation with an inventory limit that selects only a
subset of Patroni/etcd members.

With the flag enabled, the current playbook performs these steps:

1. Preflight validates the same secrets, operating system, and volume
   definitions as a new deployment.
2. Patroni is stopped on every selected host. Stop failures are currently
   tolerated to support hosts on which the service does not yet exist.
3. On one host, `patronictl remove` attempts to delete the configured Patroni
   scope from DCS when an existing Patroni configuration is present. Failure of
   this best-effort removal is tolerated.
4. The PostgreSQL data directory and local WAL archive directory are removed.
5. etcd is stopped and its complete data directory is removed. Because etcd is
   dedicated to this deployment, this destroys the entire local DCS state.
6. The normal provisioning path continues. Every configured data volume is
   unmounted, its mapper is closed, and the underlying disk receives a new
   key, LUKS2 container, LUKS UUID, and filesystem before the firewall, etcd,
   Patroni, pgBackRest, cluster checks, and application database are configured
   again.

The recreate flag replaces local cluster data and the complete encryption and
filesystem layer on every configured data disk. It does not:

- restore PostgreSQL data from a backup;
- delete physical backups from the remote pgBackRest repository;
- delete encrypted logical dump objects from S3 or MinIO;
- rotate database passwords, repository encryption secrets, or certificates
  unless different inputs are supplied separately.

> [!CAUTION]
> 🔴 **VERIFY STORAGE BEFORE CONTINUING.** In the current task order, the wipe
> runs before the LUKS stage verifies and mounts the configured volumes. Before
> recreation, confirm that both data paths are already mounted from the
> expected mappers:
>
> ```bash
> findmnt -no SOURCE --target /var/lib/pgsql
> findmnt -no SOURCE --target /var/lib/etcd
> ```
>
> Expected sources are `/dev/mapper/patroni-<postgres-volume-name>` and
> `/dev/mapper/patroni-<etcd-volume-name>`. If a path is not mounted, the wipe
> can remove a directory on the root filesystem and leave old data untouched on
> the encrypted volume that is mounted later.

> [!CAUTION]
> 🔴 **REVIEW THE BACKUP REPOSITORY BEFORE RECREATION.** Recreating PostgreSQL
> produces a new database system identifier. An existing pgBackRest stanza
> with the same `patroni_create_cluster_name` and repository path may therefore be
> incompatible with the new cluster. Decide whether to preserve the old
> repository under a separate prefix, archive it, or initialize a repository
> path for the new cluster generation. Preserve the historical values from the
> OpenBao `pgbackrest/cipher_pass` and `pgdump/cipher_pass` fields for every
> retained backup that may need to be restored.

## Firewall behavior

The role creates the configured zone, applies a `DROP` target, permits SSH from
`patroni_create_management_cidr`, permits cluster ports between all nodes, permits
PostgreSQL from `patroni_create_app_cidrs`, and makes the zone the host default. This
default-deny behavior is intentional.

## Backup behavior

The role installs full, incremental, and logical dump timers on every node.
Each job queries the local mTLS Patroni API. A replica exits successfully; an
unknown leadership state makes the job fail closed.

Logical dumps use PostgreSQL custom format, AES-256-CBC with PBKDF2, and the
configured S3 bucket. Old dumps are pruned according to
`patroni_create_dump_retention`.

## Secret rotation procedures

This role creates or recreates a cluster from known inputs. It does not rotate
secrets on a running production cluster. Updating a KV value in OpenBao does
not update PostgreSQL roles, LUKS keyslots, existing backup encryption, or
application configuration. Perform every rotation as a separate operational
procedure.

For every rotation:

1. Confirm that the Patroni cluster is healthy and identify the current leader.
2. Retain the previous secret in an approved recovery location until the new
   value has been fully tested.
3. Prevent automatic failover and unrelated maintenance for the duration of
   the change when the procedure requires it.
4. Change one component or one cluster member at a time.
5. Define and test the rollback before removing the previous value.
6. Record which backups, dumps, or encrypted volumes require each historical
   key version.

Do not put a password directly in a shell command, command-line argument,
Ansible variable, or SQL history. For PostgreSQL role passwords, connect
locally as the operating-system `postgres` user and use the interactive psql
`\password` command.

### PostgreSQL `postgres` password

OpenBao path: `pg-cluster/shared/postgresql/postgres`, field `password`.

1. Generate and retain the new and previous passwords securely.
2. Connect to the current leader through the local Unix socket:

   ```bash
   sudo -u postgres psql --no-psqlrc --dbname=postgres
   ```

3. In psql, change the role password without placing it in command history:

   ```text
   \password postgres
   ```

4. Immediately replace the `password` field at the OpenBao path. Treat the
   database change and OpenBao update as one maintenance action; do not restart
   a member or perform a failover between them.
5. Restart Patroni on one replica at a time. After each restart, verify that the
   member returns to `running` and `streaming`.
6. Perform a controlled switchover to an updated member, restart the former
   leader, and verify the complete cluster again.
7. Verify an administrative connection using the new password before closing
   the change.

To roll back, restore the previous role password on the leader, restore the
previous OpenBao value, and repeat the rolling Patroni restart.

### PostgreSQL `replicator` password

OpenBao path: `pg-cluster/shared/postgresql/replicator`, field `password`.

1. Confirm that every replica is streaming and that no switchover or failover
   is in progress.
2. Connect locally to the current leader and run:

   ```text
   \password replicator
   ```

3. Immediately replace the OpenBao `password` field. Do not trigger a failover
   between changing PostgreSQL and updating OpenBao.
4. Restart Patroni on one replica at a time so that its wrapper loads the new
   password. Confirm that replication reconnects and returns to `streaming`
   before continuing to the next replica.
5. Perform a controlled switchover to an updated replica, restart the former
   leader, and confirm that it reconnects as a replica.
6. Verify the member count, replication state, synchronous standby, and
   replication lag.

Changing the role on the leader is replicated to the other database members.
Do not execute an independent `ALTER ROLE` on each replica.

### PostgreSQL `app_user` password

OpenBao path: `pg-cluster/shared/postgresql/app_user`, field `password`.

The application and database must change credentials as one coordinated
operation because the role has one active password.

1. Drain or stop application traffic, unless the application supports a
   documented dual-credential rotation mechanism.
2. On the database leader, run `\password app_user` from an interactive local
   psql session.
3. Update the OpenBao field and the application configuration that consumes
   the credential.
4. Restart or reload the application and verify a TLS connection as
   `app_user`, followed by an application read and write check.
5. Restore application traffic only after the check succeeds.

Do not rerun the cluster creation role solely to rotate `app_user` on an
existing production cluster.

### S3 access credentials

OpenBao path: `pg-cluster/shared/s3`, fields `access_key` and `secret_key`.

1. Create a second S3 or MinIO credential while the previous credential remains
   valid.
2. Grant the new credential the same minimum permissions for the configured
   backup bucket and prefixes.
3. Replace both OpenBao fields as one change.
4. On the current leader, use `pgbackrest-wrapper` to check the repository and
   run a controlled backup. Run one logical dump and verify that its object is
   present in the expected prefix.
5. Verify that WAL archiving continues without errors.
6. Revoke the previous S3 credential only after all three checks succeed.

### pgBackRest repository cipher passphrase

OpenBao path: `pg-cluster/shared/pgbackrest`, field `cipher_pass`.

Do not overwrite this value for an existing repository. Existing repository
metadata, backups, and archived WAL depend on the original passphrase. The
safest rotation is a new repository generation:

1. Preserve the previous passphrase and repository unchanged.
2. Stop the full and incremental backup timers and confirm that no pgBackRest
   process is running.
3. Allocate a new repository prefix or repository number.
4. Store the new passphrase in OpenBao and update the pgBackRest configuration
   for the new repository as one controlled change.
5. Create the new stanza and take a new full backup immediately.
6. Perform a restore test from the new full backup.
7. Resume the backup timers and verify `archive-push` and `archive-get` against
   the intended repository.
8. Retain the previous passphrase for as long as any old backup or archived WAL
   may be restored.

### Logical dump cipher passphrase

OpenBao path: `pg-cluster/shared/pgdump`, field `cipher_pass`.

1. Preserve the previous passphrase together with the range of dump object
   names that require it.
2. Stop the logical dump timer and confirm that no dump is running.
3. Replace the OpenBao field.
4. Start one logical dump manually on the current leader.
5. Download the new object, decrypt it with the new passphrase, and verify it
   with `pg_restore --list` or a controlled restore test.
6. Resume the logical dump timer.

Existing dump objects are not re-encrypted. Keep every historical passphrase
until all corresponding objects have expired or been deliberately removed.

### LUKS2 keys

LUKS paths are node-specific:
`pg-cluster/nodes/<node>/luks/<volume>`, field `key_b64`.

Rotate one node and one volume at a time:

1. Confirm that the remaining Patroni members can maintain quorum and service
   while the selected node is restarted.
2. Generate a new random key and store it temporarily as a separate OpenBao
   field or path. Do not replace `key_b64` yet.
3. Authenticate with the current key and add the new key to a free LUKS2
   keyslot using `cryptsetup luksAddKey`.
4. Use `cryptsetup open --test-passphrase` to confirm that the new key unlocks
   the volume.
5. Replace the active OpenBao `key_b64` value with the tested new key.
6. Reboot the node and verify automatic unlock, mounts, etcd, Patroni, and
   cluster membership.
7. Only after the reboot test succeeds, remove the previous keyslot with
   `cryptsetup luksRemoveKey`.
8. Repeat for the other volume and then for the remaining nodes.

Never overwrite the only recoverable LUKS key before the new key has been
added and tested. The create/recreate workflow does not perform this rotation;
when wipe is enabled it destroys the old container and creates a new one.

### pg_tde principal key

Do not rotate the pg_tde principal key while pgBackRest, a logical dump, or a
restore operation is running.

1. Stop the backup and dump timers and confirm that no backup process remains.
2. Confirm that the cluster is healthy and that the OpenBao pg_tde key store is
   available and backed up.
3. Rotate the principal key using the pg_tde procedure approved for the
   installed extension version.
4. Verify reads and writes on encrypted tables and verify the state of every
   Patroni member.
5. Take a new full pgBackRest backup immediately and perform a restore test.
6. Resume incremental backups and logical dumps only after the full backup and
   restore test succeed.

Preserve every OpenBao key version required to restore retained backups. Exact
pg_tde commands belong to the pg_tde integration procedure because they depend
on the extension version and provider configuration.

## Validation after deployment

The role waits up to five minutes for exactly one leader, all other members in
the `streaming` state, and at least one synchronous or quorum standby.

Useful checks:

```bash
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
sudo systemctl status etcd percona-patroni
sudo systemctl list-timers 'patroni-*'
sudo -u postgres /usr/local/libexec/patroni/pgbackrest-wrapper --stanza=YOUR_CLUSTER_NAME info
findmnt /var/lib/pgsql
findmnt /var/lib/etcd
```

The deployment procedure should also validate failover, backup restoration,
and service startup after a host reboot.
