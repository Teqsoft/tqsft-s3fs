# tqsft-s3fs

A Docker-based project that mounts an AWS S3 bucket as a local filesystem and shares it via Samba (SMB) for easy access in networked environments.

## Key Features
- **S3FS Integration**: Mounts an AWS S3 bucket using `s3fs` with configurable credentials.
- **Samba Sharing**: Exposes the mounted bucket as an SMB share for cross-platform access.
- **User Management**: Supports multi-user mode with customizable UID/GID and permissions.
- **POSIX Compliance**: Shell scripts are designed to work in minimal environments (e.g., Alpine Linux).

## Configuration
### Environment Variables
- `AWS_S3_BUCKET`: Name of the S3 bucket to mount.
- `AWS_S3_ACCESS_KEY_ID`/`AWS_S3_SECRET_ACCESS_KEY`: AWS credentials (optional if using IAM roles).
- `AWS_S3_MOUNT`: Local mount path (default: `/opt/s3fs/bucket`).
- `S3FS_ARGS`: Additional `s3fs` options.

### Samba Settings
- Config file: `src/smb.conf` (customizable via `SAMBA_CONFIG`).
- Supports read-only (`RW=false`) or read-write modes.

## Usage
1. **Build the Docker Image**:
   ```sh
   podman build --tag tqsft-s3fs .
   ```

2. **Execute the Docker Image**
    ```sh
   podman run -d -p 445:445 \
  --device /dev/fuse \
  --cap-add SYS_ADMIN \
  --env-file ./env.list \
  tqsft-s3fs
  ```

## Project Structure
- src/docker-entrypoint.sh: Main entrypoint for S3FS + Samba setup.
- healthcheck.sh: Verifies S3FS mount health.
- trap.sh: Handles graceful shutdowns.
lib/tqsft-s3fs-stack.ts: AWS CDK stack (WIP for infrastructure-as-code).

## Dependencies
- s3fs: FUSE-based S3 filesystem.
- Samba: SMB/CIFS server.
- AWS-CDK: For future AWS resource provisioning.

## Notes
Requires --device /dev/fuse and --cap-add SYS_ADMIN for FUSE.
Tested with podman but compatible with docker.

### Key Files Referenced:
- `src/smb.conf`: Samba configuration template.
- `src/docker-entrypoint.sh`: Core logic for mounting and sharing.
- `package.json`: Defines build/run scripts and dependencies.