#!/bin/bash -eu

set -x

catchall() {
	if [ ${PPID-$$} -lt 2 -a $? -gt 0 ] ; then
		tail -f /dev/null
	fi
	trap - INT EXIT TERM
}
trap catchall INT EXIT TERM

# Stage 1, as root: setup system user dans groups
if [ $EUID = 0 ] ; then
	# Create postgres user matching postgres container one.
	POSTGRES_UID=$(stat -c "%u" /var/lib/postgresql/data)
	POSTGRES_GID=$(stat -c "%g" /var/lib/postgresql/data)
	if ! getent passwd postgres &>/dev/null ; then
		groupadd --system --gid ${POSTGRES_GID} postgres
		useradd --system \
			--home-dir /var/lib/postgresql --no-create-home \
			--uid ${POSTGRES_UID} --gid postgres --shell /bin/bash \
			postgres
	fi
	chown -R postgres: ~postgres /etc/temboard-agent /var/lib/temboard-agent

	# Create docker group matching docker socket ownership.
	DOCKER_GID=$(stat -c "%g" /var/run/docker.sock)
	if ! getent group ${DOCKER_GID} &>/dev/null ; then
		groupadd --system --gid ${DOCKER_GID} docker-host
		adduser postgres docker-host
	fi

	# And reexec myself as postgres.
	exec sudo -u postgres $0 "$@"
fi

# Now stage 2 as postgres user

command=${*-temboard-agent}

export PGHOST=${PGHOST-${TEMBOARD_HOSTNAME}}
export PGPORT=${PGPORT-5432}
export PGUSER=${PGUSER-postgres}
PGPASSWORD=${PGPASSWORD-}
export PGDATABASE=${PGDATABASE-postgres}

TEMBOARD_UI_URL=${TEMBOARD_UI_URL-}
export TEMBOARD_UI_USER=${TEMBOARD_UI_USER-admin}
export TEMBOARD_UI_PASSWORD=${TEMBOARD_UI_PASSWORD-admin}

network=$(docker inspect --format '{{ .HostConfig.NetworkMode }}' $HOSTNAME)
links=($(docker inspect --format '{{ $net := index .NetworkSettings.Networks "'"${network}"'" }}{{range $net.Links }}{{.}} {{end}}' $HOSTNAME))
links=(${links[@]%%:${TEMBOARD_HOSTNAME}})
PGCONTAINER=${links[@]%%*:*}
COMPOSE_SERVICE=$(docker inspect --format "{{ index .Config.Labels \"com.docker.compose.service\"}}" $HOSTNAME)

echo "Managing PostgreSQL container $PGCONTAINER." >&2

echo "Generating temboard-agent.conf" >&2

mkdir -p /etc/temboard-agent/temboard-agent.conf.d
cat > /etc/temboard-agent/temboard-agent.conf <<EOF
# Generated by $0

[temboard]
home = /var/lib/temboard-agent
users = /etc/temboard-agent/users
address = 0.0.0.0
port = 2345
ssl_cert_file = ${TEMBOARD_SSL_CERT-/usr/local/share/temboard-agent/quickstart/temboard-agent_CHANGEME.pem}
ssl_key_file = ${TEMBOARD_SSL_KEY-/usr/local/share/temboard-agent/quickstart/temboard-agent_CHANGEME.key}

[logging]
method = stderr

[postgresql]
host = /var/run/postgresql/
port = ${PGPORT}
dbname = ${PGDATABASE}
user = ${PGUSER}
password = ${PGPASSWORD}
instance = ${PGINSTANCE-main}
EOF

cat > /etc/temboard-agent/temboard-agent.conf.d/administration.conf << EOF
[administration]
pg_ctl = /usr/local/bin/pg_ctl_temboard.sh ${PGCONTAINER} %s
EOF

cat > /etc/temboard-agent/temboard-agent.conf.d/statements.conf << EOF
[statements]
dbname = ${PGDATABASE}
EOF

touch /etc/temboard-agent/users
chmod 0600 /etc/temboard-agent/users
for entry in ${TEMBOARD_USERS_LIST-alice:alice bob:bob} ; do
    echo "Adding user ${entry%%:*}."
    sed -i /${entry%:*}/d /etc/temboard-agent/users
    temboard-agent-password $entry >> /etc/temboard-agent/users
done

wait-for-it ${PGHOST}:${PGPORT}

register() {
	set -x
	hostportpath=${TEMBOARD_UI_URL#*://}
	hostport=${hostportpath%%/*}
	wait-for-it localhost:2345 -t 60
	wait-for-it ${hostport} -t 60

	temboard-agent-register \
		--host ${TEMBOARD_REGISTER_HOST-$COMPOSE_SERVICE} \
		--port ${TEMBOARD_REGISTER_PORT-2345} \
		--groups ${TEMBOARD_GROUPS-local_instances} \
		${TEMBOARD_UI_URL%/}
}

if [ -z "${command##temboard-agent*}" -a -n "${TEMBOARD_UI_USER}" ] ; then
    register &
fi

set -x
exec ${command}
