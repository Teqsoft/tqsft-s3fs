ARG ALPINE_VERSION=latest
FROM alpine:$ALPINE_VERSION

ENV AWS_S3_URL=https://s3.amazonaws.com
ENV AWS_S3_ACCESS_KEY_ID=
ENV AWS_S3_SECRET_ACCESS_KEY=
ENV AWS_S3_BUCKET=my-bucket

ENV NAME="Data"
ENV SAMBA_USER="samba"
ENV SAMBA_GROUP="smb"
ENV SAMBA_PASS="secret"
ENV SAMBA_UID=1000
ENV SAMBA_GID=1000
ENV RW=true

# User and group ID of S3 mount owner
ENV RUN_AS=
ENV UID=0
ENV GID=0

# Location of directory where to mount the drive into the container.
ENV AWS_S3_MOUNT=/opt/s3fs/bucket

# s3fs tuning
ENV S3FS_DEBUG=0
ENV S3FS_ARGS=

RUN apk --no-cache add \
      ca-certificates \
      curl \
      mailcap \
      fuse \
      libxml2 \
      libcurl \
      libgcc \
      libstdc++ \
      aws-cli \
      s3fs-fuse \
      bash \
      samba \
      tzdata \
      shadow \
      tini && \
      addgroup -S smb && \
      rm -f /etc/samba/smb.conf && \
      rm -rf /tmp/* /var/cache/apk/* && \
    s3fs --version

COPY --chmod=755 src/*.sh /usr/local/bin/
COPY --chmod=664 src/smb.conf /etc/samba/smb.conf

# allow access to volume by different user to enable UIDs other than root when
# using volumes
RUN echo user_allow_other >> /etc/fuse.conf && chmod 755 /usr/local/bin/*

WORKDIR /opt/s3fs

# Following should match the AWS_S3_MOUNT environment variable.
VOLUME [ "/opt/s3fs/bucket" ]

EXPOSE 139 445

# The default is to perform all system-level mounting as part of the entrypoint
# to then have a command that will keep listing the files under the main share.
# Listing the files will keep the share active and avoid that the remote server
# closes the connection.
ENTRYPOINT [ "tini", "-g", "--", "docker-entrypoint.sh" ]
CMD [ "empty.sh" ]