# `minio` role

## Purpose

The role installs and configures a single MinIO/AIStor server as an S3 endpoint.

The role:

- validates the required administrator credentials and operating system;
- sets the machine hostname to `minio`;
- installs the required system packages;
- opens ports 9000 and 9001 in `firewalld`;
- downloads and installs the MinIO/AIStor package;
- installs the license;
- configures the data directory and TLS;
- starts `minio.service`;
- installs the `mcli` client;
- creates an alias and a bucket.

## Scope

The current implementation creates a single node with one data directory.

## Requirements

### Target host

- Rocky Linux 9;
- systemd;
- access to the Internet or an internal MinIO/AIStor package mirror;
- an available directory or mounted disk for `minio_volumes`;
- port 9000 for the S3 API;
- port 9001 for the administrative console.

### Required role files

Before running the role, the following files must be present in
`ansible/roles/minio/files/`:

```text
files/
├── minio.license
├── public.crt
├── private.key
└── ca.crt
```

Their purposes are:

| File | Purpose |
| --- | --- |
| `minio.license` | License required by the installed AIStor package. |
| `public.crt` | MinIO HTTPS server certificate. |
| `private.key` | Private key for the server certificate. |
| `ca.crt` | CA trusted by MinIO and the `mcli` client. |

The server certificate must contain the name or address used by clients in its
Subject Alternative Name, for example `minio`, `minio1`, or the address from
`ansible_host`.

### Administrator credentials

Required variables:

```yaml
minio_admin_username: <administrator-account-name>
minio_admin_password: <password>
```

Do not store these values in plaintext in the repository. Ansible Vault is
recommended.

## Inventory

Example:

```yaml
servers:
  children:
    minio:
      hosts:
        minio1:
          ansible_host: <IP_ADDRESS>
```

## Variables

### Configuration variables

| Variable | Default | Description | Required |
| --- | --- | --- | --- |
| `minio_admin_username` | empty | MinIO administrator/root user name. | Yes |
| `minio_admin_password` | empty | MinIO administrator/root user password. | Yes |
| `minio_bucket_name` | `default-bucket` | Bucket created after the service starts. | No |
| `minio_alias` | `dev` | Alias saved in the `mcli` configuration. | No |

### Internal role paths

| Variable | Value | Description |
| --- | --- | --- |
| `minio_default_dir` | `/etc/` | Default system directory. It is not currently used directly by the tasks. |
| `minio_config_dir` | `/opt/minio` | License and certificate directory. |
| `minio_volumes` | `/mnt/drive-1/minio` | MinIO data directory. |

Before running the role, make sure that the filesystem intended for MinIO data
is mounted under the parent directory of `minio_volumes`. The role creates the
directory but does not prepare or mount a disk.

## TLS and ports

MinIO is available at:

```text
S3 API:  https://<ansible_host>:9000
Console: https://<ansible_host>:9001
```

The role opens both ports in the public firewalld zone:

```text
9000/tcp
9001/tcp
```

Access to these ports should be restricted in a production environment.

Certificates are installed at:

```text
/opt/minio/certs/public.crt
/opt/minio/certs/private.key
/opt/minio/certs/CAs/ca.crt
```

## Installation and startup

Execution order:

1. Validate the required credentials and Rocky Linux 9.
2. Set the hostname to `minio`.
3. Install `curl`, firewalld, and the Ansible firewalld dependencies.
4. Open ports 9000 and 9001.
5. Download the package from `dl.min.io/aistor`.
6. Install the RPM package.
7. Install the license, configuration, data directory, and certificates.
8. Start and enable `minio.service`.
9. Install `mcli`.
10. Add the CA for the `mcli` client.
11. Create the alias and bucket.

## Verifying a successful role run

### Service

```bash
sudo systemctl status minio --no-pager -l
sudo journalctl -u minio -n 100 --no-pager
```

### Ports

```bash
sudo ss -lntp | grep -E ':9000|:9001'
sudo firewall-cmd --list-ports
```

### Alias and bucket

```bash
sudo /usr/local/bin/mcli alias list
sudo /usr/local/bin/mcli ls <alias>
sudo /usr/local/bin/mcli stat <alias>/<bucket>
```

Example:

```bash
sudo /usr/local/bin/mcli stat test/test-bucket
```

### Write test

```bash
echo test | sudo /usr/local/bin/mcli pipe <alias>/<bucket>/healthcheck.txt
sudo /usr/local/bin/mcli cat <alias>/<bucket>/healthcheck.txt
sudo /usr/local/bin/mcli rm <alias>/<bucket>/healthcheck.txt
```
