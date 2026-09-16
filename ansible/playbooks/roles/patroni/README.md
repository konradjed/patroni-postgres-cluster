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
> before `patroni_wipe_existing_cluster` is enabled.

The role assumes full control of PostgreSQL and etcd data, dedicated data
disks, firewalld, `/etc/crypttab`, and the relevant systemd units.

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
4. Validate the configured block devices, create or open their LUKS2
   containers, create filesystems when needed, and mount the volumes.
5. Replace `/etc/crypttab` with entries managed by this role.
6. Configure the firewall, etcd, Patroni, PostgreSQL, and pgBackRest.
7. Start the cluster and backup timers.
8. Wait for a leader and streaming synchronous replicas.
9. Create or update the example application database on the leader.

## Requirements

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
- Dedicated disks matching `patroni_data_volumes`.
- Access to the configured S3 bucket.

The current topology is designed for three PostgreSQL/etcd nodes. Hostnames and
`ansible_host` addresses must match the supplied certificates.

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

Every member of `patroni_inventory_group` is used when generating the etcd
initial cluster, PostgreSQL replication rules, firewall rules, and Patroni DCS
endpoint list.

## Critical inputs before running the playbook

> [!IMPORTANT]
> The role intentionally stops cluster services, controls the host firewall,
> writes `/etc/crypttab`, and may erase the block devices declared in
> `patroni_data_volumes`. Review all values below for every host before running
> the playbook.

### Secrets required by preflight

Preflight refuses to continue when any of these variables is empty:

| Variable | Why it is required | Persistence requirement |
| --- | --- | --- |
| `patroni_postgres_password` | Password of the PostgreSQL `postgres` superuser managed by Patroni. | Keep for administration and disaster recovery. |
| `patroni_replicator_password` | Password used by Patroni members for streaming replication. | Must remain identical and available across the cluster. |
| `patroni_minio_key` | S3 access key used by pgBackRest and logical dump uploads. | Rotate together with the configured object-storage account. |
| `patroni_minio_secret` | S3 secret key. | Treat as a credential and store only in an encrypted secret source. |
| `patroni_repo_cipher_pass` | Passphrase used to encrypt the pgBackRest repository. | Losing it makes retained physical backups unusable. |
| `patroni_dump_cipher_pass` | Passphrase used by OpenSSL to encrypt logical dumps. | Losing it makes retained logical dumps unusable. |

Store these values in Ansible Vault or another encrypted variable source. Do
not place plaintext credentials in role defaults, inventory, or Git.

`patroni_app_user_password` is also required by the final application-database
bootstrap step. It is not currently part of the preflight assertion, so an
undefined value fails later when the leader executes the SQL bootstrap. Store
it with the other secrets.

### Data volumes required by preflight

`patroni_data_volumes` is required on every cluster host. Preflight checks that
each item provides a non-empty `name`, `device`, `path`, positive `gib`, and
`owner`. The LUKS stage subsequently checks that `device` exists, is a whole
block disk, and matches the declared size within a 2% tolerance.

Use a stable whole-disk path under `/dev/disk/by-id/`, never a kernel-order name
such as `/dev/nvme0n2` and never a partition ending in `-partN`.

Example host-specific configuration:

```yaml
patroni_data_volumes:
  - name: pgdata
    device: /dev/disk/by-id/nvme-eui.<postgres-device-id>
    path: /var/lib/pgsql
    gib: 10
    owner: postgres
  - name: etcd
    device: /dev/disk/by-id/nvme-eui.<etcd-device-id>
    path: /var/lib/etcd
    gib: 5
    owner: etcd
```

> [!CAUTION]
> If a configured device is not already a LUKS container, the role removes its
> existing signatures, creates a new LUKS2 container, and creates a filesystem.
> A valid device path and matching size do not prove that the disk contains no
> valuable data. Verify every device ID against the infrastructure inventory.

### LUKS key material

LUKS key files are generated automatically under `/etc/luks/luks-keys` and are
referenced from the managed `/etc/crypttab`. They are not input variables, but
they are critical secrets after the first deployment. Back them up through an
approved secret-recovery mechanism. Reinstalling a host without restoring its
key files prevents the role from opening existing encrypted data volumes.

## Role variables

### Cluster and network

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_cluster_name` | `pg_cluster` | Patroni scope, PostgreSQL cluster name, and pgBackRest stanza name. |
| `patroni_pg_token` | `PostgreSQL_HA_Cluster` | etcd token used when forming the initial cluster. |
| `patroni_inventory_group` | `psql` | Inventory group containing all Patroni and etcd nodes. |
| `patroni_management_cidr` | empty | IPv4 source allowed to use SSH. Set it before deployment; use `/32` for one address. |
| `patroni_app_cidrs` | `[]` | IPv4 CIDRs allowed to connect as `app_user` on TCP 5432. Corresponding `pg_hba` entries are generated. |
| `patroni_firewall_zone` | `patroni` | Managed firewalld zone. The role gives it a `DROP` target and makes it the default zone. |
| `patroni_firewall_ports` | `2379`, `2380`, `5432`, `8008` | TCP ports allowed between cluster nodes: etcd client, etcd peer, PostgreSQL, and Patroni REST API. |

### Storage and encryption

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_volume_fstype` | `xfs` | Filesystem created inside each LUKS mapper. It is passed to `mkfs.<value>`. |
| `patroni_data_volumes` | See below | Dedicated volumes. Each item defines a stable whole-disk `device`, mapper `name`, mount `path`, expected size in `gib`, and filesystem `owner`. Mapper names are generated as `patroni-<name>`. Override this list per host. |
| `patroni_wipe_existing_cluster` | `false` | When `true`, removes the DCS entry and PostgreSQL, WAL archive, and etcd data. It does not remove the remote backup repository. |

Default layout:

```yaml
patroni_volume_fstype: xfs
patroni_data_volumes:
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

For a configured device that is not already encrypted, the role unmounts
filesystems backed by it, removes existing signatures, creates a LUKS2
container and local key file, opens the mapper, creates the configured
filesystem, and mounts it. For an existing LUKS container, it reuses the
container and key file. If the opened mapper does not contain
`patroni_volume_fstype`, the role formats it with the configured filesystem.

Keys are stored under `/etc/luks/luks-keys` with root-only access. When reusing
an encrypted disk after rebuilding the operating system, restore its original
key file. A newly generated key cannot open an existing container.

Replacing the complete `/etc/crypttab` is intentional for these dedicated
hosts. The systemd volume guards obtain the PostgreSQL and etcd mapper names
from the entries whose paths match `/var/lib/pgsql` and `/var/lib/etcd`.

### Application database

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_app_db_name` | `app` | Database created after the cluster is healthy. Also used by the logical dump job and access rules. Use a valid PostgreSQL identifier. |
| `patroni_app_user_password` | none | Password assigned to `app_user`. Supply it from Ansible Vault. |

The bootstrap SQL creates or updates `app_user`, the local peer-authenticated
`dumper` role, the application database, and `public.ha_probe`.

### S3, pgBackRest, and dumps

| Variable | Default | Description |
| --- | --- | --- |
| `patroni_s3_endpoint` | `192.168.172.140` | S3-compatible endpoint without a scheme. HTTPS is used. |
| `patroni_s3_port` | `9000` | TLS port of the configured S3-compatible endpoint. |
| `patroni_s3_region` | `eu-central-1` | Region passed to pgBackRest and boto3. |
| `patroni_s3_bucket_name` | `patroni-bucket` | Existing bucket for backups and dumps. The role does not create it. |
| `patroni_s3_prefix` | `/pgbackrest` | pgBackRest repository path inside the bucket. |
| `patroni_dump_prefix` | `pgdump` | Independent object prefix for encrypted logical dumps. |
| `patroni_dump_retention` | `3` | Number of newest logical dumps retained under the dump prefix. |
| `patroni_dump_pass_file_location` | `/etc/pgbackrest/dump.pass` | Path of the file containing the dump encryption passphrase. The file is owned by `postgres`. |
| `patroni_on_boot_full_backup` | `3min` | Delay before the first full backup attempt after timer activation. |
| `patroni_interval_full_backup` | `30min` | Interval between full backup attempts. |
| `patroni_on_boot_incr_backup` | `5min` | Delay before the first incremental backup attempt. |
| `patroni_interval_incr_backup` | `2min` | Interval between incremental backup attempts. |
| `patroni_on_boot_dump` | `7min` | Delay before the first logical dump attempt. |
| `patroni_interval_dump` | `15min` | Interval between logical dump attempts. |

pgBackRest retains two full backups according to the generated configuration.
Timers run on every node, while `leader-gate` permits backup work only on the
current Patroni leader.

### Required secrets

The following values must be supplied, preferably from Ansible Vault:

| Variable | Purpose |
| --- | --- |
| `patroni_postgres_password` | PostgreSQL `postgres` superuser authentication. |
| `patroni_replicator_password` | Patroni replication authentication. |
| `patroni_app_user_password` | Application role authentication. This value has no role default. |
| `patroni_minio_key` | S3 access key used by pgBackRest and dump uploads. |
| `patroni_minio_secret` | S3 secret key. |
| `patroni_repo_cipher_pass` | pgBackRest repository encryption passphrase. Preserve it for restores. |
| `patroni_dump_cipher_pass` | OpenSSL dump encryption passphrase. Preserve it for decryption. |

All except `patroni_app_user_password` have empty defaults so the preflight
assertion can reject missing values.

### Internal path variables

These values are defined in `vars/main.yml` and describe the package layout.
Role vars have high precedence and are not the normal configuration interface.

| Variable | Value | Purpose |
| --- | --- | --- |
| `patroni_ca_cert_dir` | `/etc/pki/patroni` | Installed CA directory. |
| `patroni_etcd_data_dir` | `/var/lib/etcd` | etcd data directory and mountpoint. |
| `patroni_etcd_ssl` | `/etc/etcd/ssl` | etcd certificate directory. |
| `patroni_patroni_config_yaml` | `/etc/patroni/patroni.yml` | Patroni configuration file. |
| `patroni_patroni_ssl` | `/etc/patroni/ssl` | Patroni REST certificate directory. |
| `patroni_patroni_ssl_client` | `/etc/patroni/dcs-client` | Patroni etcd client certificate directory. |
| `patroni_patroni_bin` | `/usr/bin/patroni` | Patroni executable. |
| `patroni_patroni_restart_svc_type` | `on-failure` | Patroni systemd restart policy. |
| `patroni_postgres_main_dir` | `/var/lib/pgsql` | PostgreSQL parent directory and mountpoint. |
| `patroni_postgres_data_dir` | `/var/lib/pgsql/18/data` | PostgreSQL data directory. |
| `patroni_pgbackup_path` | `/var/lib/pgsql/archived` | Local archive directory removed during recreation. |
| `patroni_postgres_socket` | `/var/run/postgresql` | PostgreSQL Unix socket directory. |
| `patroni_postgres_bin` | `/usr/pgsql-18/bin` | PostgreSQL binary directory. |
| `patroni_postgres_ssl` | `/var/lib/pgsql/18/ssl` | PostgreSQL server certificate directory. |
| `patroni_pgbackrest_data_dir` | `/var/lib/pgbackrest` | pgBackRest data directory. |
| `patroni_pgbackrest_log_dir` | `/var/log/pgbackrest` | pgBackRest log directory. |
| `patroni_luks_key_dir` | `/etc/luks/luks-keys` | Local LUKS key directory. Its contents are required to reopen existing encrypted volumes. |
| `patroni_vars_postgres_password` | `{{ patroni_postgres_password }}` | Internal alias rendered into the Patroni configuration. |
| `patroni_vars_replicator_password` | `{{ patroni_replicator_password }}` | Internal alias rendered into the Patroni configuration. |

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

For an inventory containing `pg1`, `pg2`, and `pg3`, every host-specific
directory therefore needs a matching pair for all three names.

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
- the certificate presented by S3 or MinIO must chain to `ca.crt`.

The CA private key is not consumed by the role and must not be copied to target
hosts.

## Running the playbook

Run from the `ansible` directory.

### Create a new cluster

```bash
ansible-playbook playbooks/create_cluster.yml --ask-vault-pass
```

With the default `patroni_wipe_existing_cluster: false`, the wipe block is
skipped. The role then:

1. validates the operating system, required secrets, and volume definitions;
2. installs the required repositories and packages and disables conflicting
   package-provided services;
3. validates every configured device against its declared type and size;
4. creates a LUKS2 container when the device is not already encrypted, opens
   the mapper, creates the configured filesystem when absent or different, and
   mounts it;
5. replaces `/etc/crypttab` with the generated LUKS UUID and key-file entries;
6. configures the firewall, etcd, Patroni, PostgreSQL, and pgBackRest;
7. starts the cluster, waits for one leader and streaming synchronous replicas,
   and creates the application database on the leader.

> [!CAUTION]
> `patroni_wipe_existing_cluster: false` disables only the explicit cluster-data
> wipe. It does not make storage preparation non-destructive. A configured
> device without LUKS is passed through `wipefs`, `luksFormat`, and filesystem
> creation. A LUKS mapper containing a filesystem different from
> `patroni_volume_fstype` is also reformatted. New deployments require dedicated
> disks whose contents may be destroyed.

### Recreate an existing cluster

> [!CAUTION]
> 🔴 **DESTRUCTIVE AND IRREVERSIBLE OPERATION**
>
> Setting `patroni_wipe_existing_cluster=true` is an explicit request to
> destroy the local PostgreSQL cluster and the complete local etcd state on
> every selected host. Use this option only when the application is not
> required to remain available and there is an agreed need to destroy and
> rebuild the cluster. The decision must be reviewed with the application and
> database owners, including the expected data-loss boundary and backup
> recovery plan. Run it against the complete cluster inventory.

```bash
ansible-playbook playbooks/create_cluster.yml \
  --ask-vault-pass \
  -e patroni_wipe_existing_cluster=true
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
6. The normal provisioning path continues: packages, LUKS volumes, firewall,
   etcd, Patroni, pgBackRest, cluster checks, and the application database are
   configured again.

The recreate flag removes logical cluster data but does not intentionally
replace an existing LUKS container, LUKS UUID, key file, or matching filesystem.
Those are reused when they can be opened successfully. It also does not:

- restore PostgreSQL data from a backup;
- delete physical backups from the remote pgBackRest repository;
- delete encrypted logical dump objects from S3 or MinIO;
- rotate database passwords, repository encryption secrets, certificates, or
  LUKS keys unless different inputs are supplied separately.

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
> with the same `patroni_cluster_name` and repository path may therefore be
> incompatible with the new cluster. Decide whether to preserve the old
> repository under a separate prefix, archive it, or initialize a repository
> path for the new cluster generation. Preserve `patroni_repo_cipher_pass` and
> `patroni_dump_cipher_pass` for every retained backup that may need to be
> restored.

## Firewall behavior

The role creates the configured zone, applies a `DROP` target, permits SSH from
`patroni_management_cidr`, permits cluster ports between all nodes, permits
PostgreSQL from `patroni_app_cidrs`, and makes the zone the host default. This
default-deny behavior is intentional.

## Backup behavior

The role installs full, incremental, and logical dump timers on every node.
Each job queries the local mTLS Patroni API. A replica exits successfully; an
unknown leadership state makes the job fail closed.

Logical dumps use PostgreSQL custom format, AES-256-CBC with PBKDF2, and the
configured S3 bucket. Old dumps are pruned according to
`patroni_dump_retention`.

## Validation after deployment

The role waits up to five minutes for exactly one leader, all other members in
the `streaming` state, and at least one synchronous or quorum standby.

Useful checks:

```bash
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
sudo systemctl status etcd percona-patroni
sudo systemctl list-timers 'patroni-*'
sudo -u postgres pgbackrest --stanza=pg_cluster info
findmnt /var/lib/pgsql
findmnt /var/lib/etcd
```

The deployment procedure should also validate failover, backup restoration,
and service startup after a host reboot.
