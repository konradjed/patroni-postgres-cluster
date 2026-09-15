# Patroni PostgreSQL cluster bootstrap and recreation

The `patroni` role provisions a PostgreSQL 18 high-availability cluster on the
hosts in the configured inventory group. It is called by
`ansible/playbooks/create_cluster.yml`.

This role is intended for bootstrapping a cluster on new machines and for
destructively recreating a cluster during a planned maintenance window.
Configuration changes on a running cluster are handled by a separate role.

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

1. Validate required secrets and the operating system.
2. Optionally remove the existing DCS entry, PostgreSQL data, WAL archive, and
   etcd data.
3. Install packages and prepare services.
4. Identify, encrypt, format, and mount data volumes.
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
- Access to the encrypted group variables.
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
- Access to the configured S3 or MinIO endpoint and bucket.

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
| `patroni_data_volumes` | See below | Dedicated volumes. Each item defines `name`, mount `path`, expected size in `gib`, and filesystem `owner`. Mapper names are generated as `patroni-<name>`. |
| `patroni_wipe_existing_cluster` | `false` | When `true`, removes the DCS entry and PostgreSQL, WAL archive, and etcd data. It does not remove the remote backup repository. |

Default layout:

```yaml
patroni_volume_fstype: xfs
patroni_data_volumes:
  - name: pgdata
    path: /var/lib/pgsql
    gib: 10
    owner: postgres
  - name: etcd
    path: /var/lib/etcd
    gib: 5
    owner: etcd
```

The current implementation identifies raw devices by size with a 2% tolerance.
Exactly one device must match each configured size. Sizes must be unique on a
host and must not match any disk that should be preserved.

For an unencrypted matching device, the role unmounts filesystems backed by it,
removes existing signatures, creates a LUKS2 container and key file, opens the
mapper, creates the filesystem when missing, and mounts it.

Keys are stored under `/etc/patroni/luks` with root-only access. When reusing an
already encrypted disk after rebuilding the operating system, restore its
original key file. A newly generated key cannot open an existing container.

Replacing the complete `/etc/crypttab` is intentional for these dedicated
hosts. The current systemd units expect `/dev/mapper/patroni-pgdata` and
`/dev/mapper/patroni-etcd`, so keep the names `pgdata` and `etcd` unless their
unit templates are also changed.

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
| `patroni_s3_port` | `443` | HTTPS port of the endpoint. |
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
| `patroni_luks_key_dir` | `/etc/patroni/luks` | Local LUKS key directory. |
| `patroni_vars_postgres_password` | `{{ patroni_postgres_password }}` | Internal alias rendered into the Patroni configuration. |
| `patroni_vars_replicator_password` | `{{ patroni_replicator_password }}` | Internal alias rendered into the Patroni configuration. |

## Certificates

Certificates and private keys are supplied outside Git. A separate script can
generate them for tests; production certificates must be staged before running
the playbook.

Expected layout below `ansible/playbooks/roles/patroni/files/certs/`:

```text
ca/ca.crt
etcd/etcd-<hostname>.crt
etcd/etcd-<hostname>.key
patroni/patroni-<hostname>.crt
patroni/patroni-<hostname>.key
dcs-client/dcsclient-<hostname>.crt
dcs-client/dcsclient-<hostname>.key
postgres/pgsrv-<hostname>.crt
postgres/pgsrv-<hostname>.key
```

etcd and Patroni REST certificates need server and client authentication usage.
DCS certificates need client usage, and PostgreSQL certificates need server
usage. Server certificates must contain the inventory hostname and IP address.
Certificates used for local health checks must also cover `127.0.0.1` where
applicable. The same CA verifies the S3 or MinIO endpoint.

The CA private key is not required by this role and must not be copied to target
hosts.

## Running the playbook

Run from the `ansible` directory.

### New deployment

```bash
ansible-playbook playbooks/create_cluster.yml --ask-vault-pass
```

### Destructive recreation

```bash
ansible-playbook playbooks/create_cluster.yml \
  --ask-vault-pass \
  -e patroni_wipe_existing_cluster=true
```

Run recreation against the complete cluster inventory during a maintenance
window. It does not restore a backup or delete the remote pgBackRest repository
and logical dumps. A new PostgreSQL cluster has a new system identifier, so
decide how the deployment will separate or replace an existing pgBackRest stanza.

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
