#!/usr/bin/env bash

log() {
    echo "----> $1"
}

stop()
{
  log 'caught SIGTERM or SIGINT'

  log 'unexporting filesystems'
  /usr/sbin/exportfs -ua

  log 'stopping nfsd'
  /usr/sbin/rpc.nfsd --debug 8 0

  log 'killing mountd'
  kill -TERM "$(pidof rpc.mountd)"

  log 'terminated cleanly'
  exit 0
}

setupTrap()
{
  trap 'stop' SIGTERM SIGINT
}

checkCommandResult()
{
  if [ $? -ne 0 ]; then

    log "$1"
    exit 1
  fi
}

ensureKernelModule()
{
  log "checking for presence of kernel module: $1"

  lsmod | grep -Eq "^$1\\s+"

  checkCommandResult "$1 module is not loaded on the Docker host's kernel (try: modprobe $1)"
}

checkUserEnvNfsdPort()
{
  if [[ -n "$NFSD_PORT" && ( "$NFSD_PORT" -lt 1 || "$NFSD_PORT" -gt 65535 ) ]]; then

    log 'Please set NFSD_PORT to a value between 1 and 65535 inclusive'
    exit 1
  fi
}

checkUserEnvNfsVersion()
{
  if [ -z "$NFS_VERSION" ]; then
    return
  fi

  local allowed=('4' '4.1' '4.2')

  for allowedVersion in "${allowed[@]}"; do

    if [[ "$allowedVersion" == "$NFS_VERSION" ]]; then
      return
    fi
  done

  log 'Please set NFS_VERSION to 4, 4.1, or 4.2'
  exit 1
}

checkUserEnvNfsdServerThreads()
{
  if [[ -n "$NFSD_SERVER_THREADS" && "$NFSD_SERVER_THREADS" -lt 1 ]]; then

    log 'Please set NFSD_SERVER_THREADS to a positive value'
    exit 1
  fi
}

checkPrereqs()
{
  # check kernel modules
  ensureKernelModule nfs
  ensureKernelModule nfsd

  # ensure /etc/exports has at least one line
  grep -Evq '^\s*#|^\s*$' /etc/exports
  checkCommandResult '/etc/exports has no exports'

  # ensure we have CAP_SYS_ADMIN
  capsh --print | grep -Eq "^Current: = .*,?cap_sys_admin(,|$)"
  checkCommandResult 'missing CAP_SYS_ADMIN. be sure to run Docker with --cap-add SYS_ADMIN or --privileged'

  # validate any user-supplied environment variables
  checkUserEnvNfsdPort
  checkUserEnvNfsVersion
  checkUserEnvNfsdServerThreads

  log 'requirements look good'
}

buildExports()
{
  if mount | grep -Eq '^[^ ]+ on /etc/exports type '; then

    log '/etc/exports appears to be mounted via Docker'
    return
  fi

  local collected=0
  local exports=''
  local candidateDirs

  candidateDirs=$(compgen -A variable | grep -E 'NFS_EXPORT_DIR_[0-9]*')
  checkCommandResult 'missing NFS_EXPORT_DIR_* environment variable(s)'

  log 'building /etc/exports'

  for dir in $candidateDirs; do

    local index=${dir##*_}
    local net=NFS_EXPORT_CLIENT_$index
    local opt=NFS_EXPORT_OPTIONS_$index

    if [ ! -d "${!dir}" ]; then

      log "skipping $dir (${!dir}) since it is not a directory"
      continue
    fi

    if [[ -n ${!net} ]] && [[ -n ${!opt} ]]; then

      log "will export ${!dir} to ${!net} with options ${!opt}"

      local line="${!dir} ${!net}(${!opt})"

      if [ $collected -gt 0 ]; then
        exports=$exports$'\n'
      fi

      exports=$exports$line

      (( collected++ ))

     else

        log "skipping $dir (${!dir}) as it is missing domain and/or options. be sure to set both $net and $opt."
     fi
  done

  if [ $collected -eq 0 ]; then

    log 'no directories to export.'
    exit 1
  fi

  log "will export $collected filesystem(s)"

  echo "$exports" > /etc/exports

  log '/etc/exports now contains the following contents:'
  cat /etc/exports
}

start()
{
  local nfsdThreads=${NFSD_SERVER_THREADS:-$(grep -c ^processor /proc/cpuinfo)}
  local nfsVersion=${NFS_VERSION:-4.2}
  local nfsPort=${NFSD_PORT:-2049}

  while [ -z "$(pidof rpc.mountd)" ]; do

    # rpcbind isn't required for NFSv4, but if it's not running then nfsd takes over 5 minutes to start up.
    # it's a bug in either nfs-utils on the kernel, and the code of both is over my head.
    # so as a workaround we start rpcbind now and kill it after nfsd starts up
    log 'starting rpcbind temporarily to allow rpc.nfsd to start quickly'
    /sbin/rpcbind -ds
    checkCommandResult 'rpcbind failed'

    log "starting rpc.nfsd on port $nfsPort with version $nfsVersion and $nfsdThreads server thread(s)"
    /usr/sbin/rpc.nfsd --debug 8 --no-nfs-version 2 --no-nfs-version 3 --nfs-version "$nfsVersion" "$nfsdThreads"
    checkCommandResult 'rpc.nfsd failed'

    log 'killing rpcbind now that rpc.nfsd is up'
    kill -TERM "$(pidof rpcbind)"
    checkCommandResult 'unable to kill rpcbind'

    log 'exporting filesystems'
    /usr/sbin/exportfs -arv
    checkCommandResult 'exportfs failed'

    log "starting rpc.mountd with version $nfsVersion"
    /usr/sbin/rpc.mountd --debug all --no-nfs-version 2 --no-nfs-version 3 --nfs-version "$nfsVersion"
    checkCommandResult 'rpc.mountd failed'

    if [ -z "$(pidof rpc.mountd)" ]; then

      log 'startup failed, sleeping for 2 seconds before retry'
      sleep 2
    fi

  done

  log "nfsd ready and waiting for client connections on port $nfsPort"

  # https://stackoverflow.com/questions/2935183/bash-infinite-sleep-infinite-blocking
  while :; do sleep 2073600; done
}

setupTrap
buildExports
checkPrereqs
start
