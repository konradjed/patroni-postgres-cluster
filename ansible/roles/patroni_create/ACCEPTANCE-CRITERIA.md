# Key and secret management acceptance criteria

This document describes two alternative approaches to securing the cluster:

- `OB` - centralised key and secret management with OpenBao
- `TP` - LUKS2 unlocking with vTPM, with the remaining secrets stored as
  encrypted systemd credentials that are also bound to the vTPM.

For each approach, `ER` criteria define the requirements and checks before
deployment, while `PT` criteria define the tests and expected results after
deployment.

Tests that affect availability must be performed on one replica at a time,
after confirming that the remaining cluster members are healthy.

Links in the criteria below point to the relevant sections of the
[role documentation](README.md).

## OB approach - OpenBao

### Requirements and checks before deployment

| ID | Requirement | Verification method | Acceptance condition |
| --- | --- | --- | --- |
| OB-ER-01 | Each node has dedicated block devices for PostgreSQL and etcd. See [Data volumes required by preflight](README.md#data-volumes-required-by-preflight). | Run `lsblk --bytes --output NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS`. | The devices exist, have the expected size, contain no required data, and are not used by the operating system. |
| OB-ER-02 | Each node can reach OpenBao only through an encrypted HTTPS connection and can verify its certificate. See [Deployment infrastructure](README.md#deployment-infrastructure) and [OpenBao and `pg_tde`](README.md#openbao-and-pg_tde). | Perform the initial connectivity check by running `curl` directly on every node against the configured OpenBao HTTPS address with the trusted CA. Also use `curl` to attempt a plaintext HTTP connection and repeat the HTTPS test with an incorrect CA. | Verified HTTPS succeeds. A plaintext HTTP connection cannot access OpenBao, and HTTPS with an incorrect CA is rejected. No unencrypted OpenBao listener is available to the cluster nodes. |
| OB-ER-03 | OpenBao has the required logical structure. See [OpenBao secret layout](README.md#openbao-secret-layout). | Check the namespace, certificate authentication method, and KV v2 engines for the cluster secrets and `pg_tde`. | The required namespace, authentication mount, and both secret engines exist at paths matching the role configuration. |
| OB-ER-04 | All required secrets exist before deployment. See [Secrets required before provisioning](README.md#secrets-required-before-provisioning) and [OpenBao secret layout](README.md#openbao-secret-layout). | Verify the LUKS key paths for every node and the PostgreSQL, NetApp, pgBackRest, and dump secrets. | Every required path and field exists, the values are not empty, and the LUKS keys are unique for every node and volume. |
| OB-ER-05 | Each node has a separate OpenBao client certificate. See [Required role files](README.md#required-role-files). | Check the trust chain, validity period, certificate purpose, and whether the node name matches the certificate authentication role. | The certificate is valid, signed by a trusted CA, and accepted only by the role assigned to the correct node. |
| OB-ER-06 | OpenBao policies follow the principle of least privilege. See [Expected OpenBao policy](README.md#expected-openbao-policy). | For each node token, check its capabilities for its own LUKS keys, shared secrets, `pg_tde` paths, and the keys of other nodes. | The node can read its own LUKS keys and the required shared secrets, and can perform the required `pg_tde` operations. It cannot read the LUKS keys of other nodes or access administrative paths. |
| OB-ER-07 | OpenBao has a defined recovery procedure. | Check the current OpenBao data backup and the server unsealing procedure. | OpenBao and its secrets can be restored. |
| OB-ER-08 | A NetApp bucket is available for backups, WAL, and dumps. See [NetApp, pgBackRest, and dumps](README.md#netapp-pgbackrest-and-dumps). | Check the TLS connection, account permissions, the ability to write and delete a test object, and the available capacity. | Every node can connect to the endpoint, and the account has only the permissions required for the specified bucket and prefixes. |
| OB-ER-09 | OpenBao, NetApp, etcd, Patroni, and PostgreSQL certificates use a common trusted root CA. They may be signed directly by that root or by intermediate CAs belonging to chains that terminate at the same root. See [Deployment infrastructure](README.md#deployment-infrastructure) and [Required role files](README.md#required-role-files). | Verify every certificate chain, including the required intermediate certificates, and confirm that its root is the certificate supplied to the role as `certs/ca/ca.crt`. Confirm that the role imports that same certificate into every node as `/etc/pki/ca-trust/source/anchors/patroni-intra-ca.crt`. | Every chain terminates at the shared root imported into the node trust store, clients validate the service certificates without disabling verification, SANs contain the names or addresses used by clients, and EKUs match the service purpose. |

### Tests and expected results after deployment

| ID | Test | Execution method | Expected result |
| --- | --- | --- | --- |
| OB-PT-01 | Data volume encryption. See [Volumes validation](README.md#volumes). | Check `lsblk --fs`, `findmnt /var/lib/pgsql`, `findmnt /var/lib/etcd`, and `cryptsetup status` for both mappings. | PostgreSQL and etcd use the correct separate `crypto_LUKS` devices mounted at the expected paths. |
| OB-PT-02 | OpenBao Agent authentication. See [Execution flow](README.md#execution-flow). | Check the status and logs of `openbao-agent.service` and the `/run/openbao-agent/token` file. | The Agent is running, authenticates with the certificate assigned to the node, writes a non-empty renewable token with limited permissions, and renews it correctly. |
| OB-PT-03 | Permission isolation between nodes. See [Expected OpenBao policy](README.md#expected-openbao-policy). | Using one node's token, read its LUKS path, a shared secret, and the LUKS path of another node. | The first two reads are allowed, while the attempt to read another node's key returns `permission denied`. |
| OB-PT-04 | No local copies of LUKS keys. See [LUKS key material](README.md#luks-key-material). | Check `/etc/luks`, `/etc/crypttab`, service configuration, and directories used by the role. | LUKS keys are not present in local files, and managed volumes have no entries that reference a local key file. |
| OB-PT-05 | Correct service startup order. See [Systemd dependencies and service startup](README.md#systemd-dependencies-and-service-startup). | Restart one replica and observe `openbao-agent`, `patroni-unlock-volumes`, `etcd`, and `percona-patroni`. | The Agent obtains a token, the volumes are unlocked and mounted, and etcd and Patroni start only after the mappings and mounts pass validation. |
| OB-PT-06 | Safe startup behaviour when OpenBao is unavailable. See [After a machine or service restart](README.md#after-a-machine-or-service-restart). | On one replica, deliberately block access to OpenBao and restart the volume unlocking and cluster services. | The volumes remain locked, and etcd and Patroni do not start against empty directories. After OpenBao is restored, the services regain access and the replica rejoins the cluster. |
| OB-PT-07 | Scope of an OpenBao outage. See [Behavior when OpenBao is unavailable](README.md#behavior-when-openbao-is-unavailable). | While the cluster is running, temporarily stop OpenBao and check mounted volumes, basic database reads and writes, and operations that require a fresh secret retrieval. | Volumes that have already been unlocked remain mounted, and the running cluster is not stopped automatically. Operations requiring a new secret retrieval fail in a controlled manner. |
| OB-PT-08 | No secrets in persistent configuration. See [Backup behavior](README.md#backup-behavior). | Review the Patroni, pgBackRest, and pg_back configuration, systemd units, and process environments without printing the token value. | PostgreSQL passwords, NetApp credentials, the repository password, and private encryption keys are not stored in plaintext configuration or passed as process arguments. |
| OB-PT-09 | `pg_tde` encryption. See [`pg_tde` configuration](README.md#pg_tde-configuration) and [`pg_tde` validation](README.md#pg_tde). | Run `pg_tde_verify_default_key()`, check the default provider, `default_table_access_method`, and `pg_tde.enforce_encryption`, and then create a test table. | The OpenBao provider and default key are available, the access method is `tde_heap`, encryption enforcement is enabled, and the new table uses TDE. |
| OB-PT-10 | Physical backup, WAL archiving, and logical dump. See [Backup behavior](README.md#backup-behavior) and [Backups validation](README.md#backups). | Run a pgBackRest backup and a dump, and check their status and the presence of objects in NetApp. | The operations complete successfully, objects are written to the correct prefixes, and the backup and dump are encrypted and can be read using the appropriate recovery procedures. |
| OB-PT-11 | Cluster availability after losing a node. See [Cluster validation](README.md#cluster). | Write data, stop the current leader, observe the election of a new leader, and then restore the stopped node. | A new leader is elected without losing a committed transaction, and the restored node synchronises its data and rejoins as a replica. |

## TP approach - vTPM, LUKS2, and systemd credentials

Each machine has its own vTPM, which is a virtual security module with a unique
cryptographic state. LUKS2 uses it to unlock volumes automatically only on the
correct machine. Unlocking can additionally be bound to the system boot state
through a PCR policy, so an unexpected change to firmware, the bootloader, or
the boot configuration can be rejected. The vTPM state is maintained and
protected by the virtualisation platform and its Key Provider. Copying only
the VM disks or adding a new vTPM does not recreate the previous cryptographic
identity and does not provide automatic unlocking.

The remaining passwords and keys are stored as encrypted systemd credential
files bound to the correct vTPM. Systemd decrypts them when starting a service
and makes them available only to that service. If a required credential cannot
be decrypted, the service will not start.

> **Risk of permanent data loss:** losing or resetting the vTPM without a
> valid copy of the recovery keys prevents the LUKS2 volumes from being
> unlocked. In this situation, the data cannot be recovered. Recovery keys
> must be stored outside the cluster nodes and verified before the environment
> is approved for use. The source values used to create systemd credentials
> must also exist in a separate secure store.

### Requirements and checks before deployment

| ID | Requirement | Verification method | Acceptance condition |
| --- | --- | --- | --- |
| TP-ER-01 | Each machine has its own vTPM 2.0. | Check the virtual machine configuration in the hypervisor, the presence of `/dev/tpmrm0` or `/dev/tpm0`, and the result of `systemd-creds has-tpm2`. | Every node detects a working TPM2, and its vTPM state is unique to the machine and persists across a normal restart. |
| TP-ER-02 | The hypervisor securely stores and protects the vTPM state. | Check VM encryption, backup and migration settings, and hypervisor administrator permissions. | The vTPM state is not stored or exported in plaintext, and access to it is restricted and audited. |
| TP-ER-03 | The virtualisation platform preserves the vTPM state during supported VM operations. | Review the configuration and documentation for VM migration, backup, and restoration. If necessary, verify the behaviour using a separate test machine. | For every supported operation, it is known whether the vTPM state will be preserved. In VMware, the correct Key Provider, its secure backup, and the keys required to restore the VM are also available. |
| TP-ER-04 | The operating system version supports TPM2, LUKS2, and encrypted systemd credentials. | Check the systemd version and the availability of the required packages in the configured repositories. | The system provides `systemd-cryptenroll`, `systemd-creds`, `systemd-cryptsetup`, the required TPM2 libraries, `tpm2-device=auto`, and `LoadCredentialEncrypted=`. |
| TP-ER-05 | The boot environment supports the agreed PCR policy. | Check the boot mode, available PCRs, and Secure Boot state if the selected policy uses it. | Boot measurements are available and stable, and a recovery and re-enrolment procedure is defined for bootloader, kernel, or firmware updates. |
| TP-ER-06 | Each node has dedicated block devices for PostgreSQL and etcd. See [Data volumes required by preflight](README.md#data-volumes-required-by-preflight). | Run `lsblk --bytes --output NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS`. | The devices exist, have the expected size, are not used by the operating system, and can be assigned to LUKS2. |
| TP-ER-07 | All secret values required by the role are available from an approved deployment source. | Check Ansible Vault or another encrypted input store without displaying secret values. | PostgreSQL passwords, NetApp credentials, the pgBackRest password, and all other required secrets are complete and do not appear in plaintext in the inventory or repository. |
| TP-ER-08 | A protected store outside the cluster nodes exists for LUKS2 recovery keys and source values used by systemd credentials. | Check the target location and the procedure for storing recovery material created or used by the role. | The store is encrypted, access is restricted, and it allows the volumes to be recovered and credentials to be recreated after losing a vTPM or a node. Deployment is not accepted until the recovery keys and source secrets have been stored and verified. |
| TP-ER-09 | The NetApp bucket, network connectivity, and PKI material are ready for deployment. Service certificates may be signed by the shared root or by intermediate CAs whose chains terminate at that root. See [NetApp, pgBackRest, and dumps](README.md#netapp-pgbackrest-and-dumps) and [Required role files](README.md#required-role-files). | Check access to the NetApp endpoint from the nodes, account permissions, and all PostgreSQL, etcd, Patroni, and NetApp certificate chains. Confirm that their root is the certificate supplied as `certs/ca/ca.crt` and imported by the role into every node. | The bucket exists, the account can access only the required resources, and every complete certificate chain terminates at the same root CA present in the node trust store. |

### Tests and expected results after deployment

| ID | Test | Execution method | Expected result |
| --- | --- | --- | --- |
| TP-PT-01 | Presence of the correct vTPM. | Run `systemd-creds has-tpm2`, list the available TPM2 devices, and compare node identities. | Every node detects its own working TPM2. The nodes do not use a shared emulated device. |
| TP-PT-02 | LUKS2 enrolment with vTPM and creation of an independent recovery key. | Check `cryptsetup luksDump`, `/etc/crypttab`, and the presence of a protected copy of the key outside the node without displaying its value. | Every volume has a `systemd-tpm2` token and a separate active recovery slot, the recovery key is stored securely outside the node, and `crypttab` uses `tpm2-device=auto` without a local key file. |
| TP-PT-03 | Volume encryption and mounting. See [Volumes validation](README.md#volumes). | Check `lsblk --fs`, `findmnt`, and `cryptsetup status` for both mappings. | PostgreSQL and etcd run on the correct separate `crypto_LUKS` devices, and the mount points reference the expected mappings. |
| TP-PT-04 | Automatic unlocking after restart. | Restart one replica and observe the cryptsetup units, mounts, etcd, and Patroni. | The vTPM unlocks both volumes without a local plaintext key or operator involvement, and services start only after the correct devices have been mounted. |
| TP-PT-05 | Safe behaviour without the correct vTPM or when the PCR policy is not satisfied. | Start a controlled test copy without the vTPM state or with a changed state covered by the PCR policy. | Automatic unlocking is rejected, and etcd and Patroni do not start against empty directories. The original node remains unaffected. |
| TP-PT-06 | Recovery key operation. | On a controlled test volume, unlock LUKS2 with the recovery key without using the old vTPM, and then enrol a new vTPM. | The recovery key provides an independent way to unlock the volume, the data is readable, and automatic unlocking through the new vTPM works after re-enrolment. |
| TP-PT-07 | Creation and protection of encrypted credentials. | Check the files created by the role, start a service that uses them, and then attempt to use a copied credential on another node without revealing its value. | The service receives the correct secret, but another node cannot decrypt the copied file. After losing a vTPM, the credential can be recreated from the source value stored outside the node. |
| TP-PT-08 | Unit configuration and delivery of secrets to the correct services. | Check the units created by the role, their `LoadCredentialEncrypted=` directives, the credential directory of a running service, and a basic operation performed by that service. | Each service receives only the secrets it requires, and their plaintext values are available only in the protected credential directory while the service is running. |
| TP-PT-09 | No plaintext secrets on the system. | Review the Patroni, pgBackRest, and pg_back configuration, systemd units, process environments, and process arguments. | Passwords, NetApp credentials, and the repository password do not appear in persistent plaintext files, environment variables, or process arguments. |
| TP-PT-10 | Physical backup, WAL, and logical dump. See [Backup behavior](README.md#backup-behavior) and [Backups validation](README.md#backups). | Run a pgBackRest backup and a dump, and check the objects in NetApp. | The services receive the correct credentials, the operations complete successfully, and the resulting backups and dumps are encrypted and recoverable. |
| TP-PT-11 | Cluster availability after losing a node. See [Cluster validation](README.md#cluster). | Write data, stop the leader, observe the failover, and then restore the stopped node. | The cluster elects a new leader without losing a committed transaction, and the restored node unlocks its volumes through vTPM, synchronises its data, and rejoins as a replica. |

## Encryption implementation with vTPM

- **LUKS2 + Clevis:** LUKS2 encrypts the PostgreSQL and etcd volumes, while
  Clevis binds their automatic unlocking to the correct vTPM.

- **Secrets + systemd-creds:** passwords and keys are stored in encrypted form
  using the vTPM, and systemd decrypts them only when starting the appropriate
  service.

## Operating and recovery principles for the TP approach

The following principles define what is required for secure operation and how
to recover access after losing a vTPM or an entire node.

- A vTPM is assigned to a specific machine. It prevents the LUKS2 automatic
  unlocking mechanism and encrypted systemd credentials from being used on
  another node.
- The LUKS2 recovery key is independent of the vTPM and is stored in a separate
  slot. After losing a vTPM, it allows the volume to be unlocked and a new vTPM
  to be enrolled.
- The recovery key must be stored outside the cluster and tested periodically.
  Knowing that it was generated does not confirm that it works.
- Systemd credentials are encrypted copies of passwords and keys required by
  services. After losing a vTPM, these files may no longer be usable. The
  original secret values must therefore be retained outside the node and used
  when required, for example to decrypt a backup created by pgBackRest.
- Restoring a VMware virtual machine must include the state of its existing
  vTPM. Adding a new empty vTPM does not restore keys bound to the previous
  device.
- VMware must have access to the same Key Provider and the keys that protected
  the vTPM state. Without them, the machine may fail to start or the vTPM may
  not be restored correctly.
- The machine's boot state must satisfy the PCR policy used during encryption.
  A change to firmware, Secure Boot, the bootloader, or another covered element
  may block automatic decryption and require the recovery procedure.
- In systemd credentials `host+tpm2` mode, a secret is bound both to the vTPM
  and the local `/var/lib/systemd/credential.secret` key. A full VM backup
  should preserve both elements, but a new operating system installation with
  the restored vTPM cannot decrypt an old credential without this file. In
  that situation, the credential must be recreated from the source secret.

## Protection boundaries of the TP approach

The vTPM prevents LUKS2 keys and systemd credentials from being used after
only a disk or an encrypted file has been copied to another machine. It does
not protect against compromise of a running system as `root`, access to a
secret that has already been provided to a process, or a hypervisor
administrator capable of capturing the complete machine together with its
running vTPM state.

**Losing or resetting the vTPM without an available copy of the LUKS2 recovery
keys results in permanent loss of access to the data on the encrypted
volumes.** A missing key cannot be recreated from the encrypted disk alone.
The LUKS2 recovery keys and source values of the remaining secrets must
therefore be kept in a separate approved encrypted recovery store. Their
presence and operation must be verified before the environment is approved
for use.
