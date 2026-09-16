#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# vscode_dgx — script de arranque de code-server dentro del SIF DGX.
#
# Hardenings aplicados tras pentest 2026-05-14:
#   - BIND_PATHS mínimo (sin /etc/slurm, /run/munge, /scratch, /shared,
#     Modules, /usr/libexec completo)
#   - /home filtrado a /home/$USER (cierra enumeración de usuarios)
#   - /etc/subuid /etc/subgid filtrados al vuelo (cierra mapping global)
#   - apptainer --pid --ipc (cierra ptrace cross-namespace y SHM compartido)
#   - code-server --bind-addr <NODE_IP>:<port> (no 0.0.0.0)
#   - Log centralizado en /shared/ood-sessions/logs/$USER/${jobid}_${port}.log
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# USER no siempre viene en el entorno del job Slurm (según nodo / --export);
# derivarlo del UID con el que corre el job para no abortar bajo `set -u`.
export USER="${USER:-$(id -un)}"
# Normalizar al nombre CORTO: SSSD puede devolver el canonico con dominio para
# los alumnos (202005859@alumnos.upcont.es). El corto es el que usan el home,
# /raid/dgx, las asociaciones de Slurm y el marcador de propiedad que valida
# node_proxy.lua -- si aqui se cuela el largo, el proxy deniega con 500.
USER="${USER%%@*}"
export USER

# ─── Logging centralizado por sesión ────────────────────────────────────────
# Logs en el RAID PROPIO del usuario, no en un directorio compartido 1777:
# nada escribible en comun = nada que sembrar ni que fisgar.
LOG_DIR="/raid/dgx/${USER}/.ood-logs"
[ -d "/raid/dgx/${USER}" ] || LOG_DIR="${HOME}/.ood-logs"
JOBID="${SLURM_JOB_ID:-nojob}"
HOSTSHORT="$(hostname -s)"
LOG_FILE="${LOG_DIR}/${HOSTSHORT}_${JOBID}_${port}.log"

mkdir -p "$LOG_DIR" 2>/dev/null && chmod 700 "$LOG_DIR" 2>/dev/null
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== vscode_dgx START ==="
log "Host: $(hostname -f) · Job: ${JOBID} · Puerto: ${port} · User: ${USER}"
log "Log central: ${LOG_FILE}"

APPTAINER_IMAGE="/shared/containers/vscode_dgx.sif"

# ─── IP de gestión del nodo (no 0.0.0.0) ────────────────────────────────────
NODE_IP="$(hostname -i | awk '{print $1}')"
log "NODE_IP: ${NODE_IP}"

# ─── XDG_RUNTIME_DIR para dockerd-rootless ──────────────────────────────────
# único POR SESIÓN (incluye ${port}): si fuera solo per-user, dos sesiones del
# mismo usuario en el mismo nodo (p.ej. jupyter + vscode) comparten socket y
# data-root de dockerd-rootless y se pisan → `docker ps` falla en una de ellas.
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)-${port}"
# /tmp es 1777: otro usuario puede PRE-CREAR este directorio y quedarse dentro
# el socket de nuestro dockerd -> ejecutaria contenedores con NUESTRA identidad.
# Si existe y no es nuestro, o no se puede dejar en 0700, se aborta la sesion.
if [ -e "$XDG_RUNTIME_DIR" ] && [ ! -O "$XDG_RUNTIME_DIR" ]; then
    log "ERROR: ${XDG_RUNTIME_DIR} existe y NO es tuyo. Posible intento de"
    log "       apropiacion del socket de Docker. Sesion abortada."
    exit 1
fi
mkdir -p "$XDG_RUNTIME_DIR" || { log "ERROR: no se pudo crear ${XDG_RUNTIME_DIR}"; exit 1; }
chmod 700 "$XDG_RUNTIME_DIR" || { log "ERROR: no se pudo asegurar 0700 en ${XDG_RUNTIME_DIR}"; exit 1; }
export APPTAINERENV_XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"

# ─── dockerd-rootless: daemon Docker per-sesión ─────────────────────────────
DOCKER_SOCK="${XDG_RUNTIME_DIR}/docker.sock"
DOCKERD_LOG="${XDG_RUNTIME_DIR}/dockerd.log"
DOCKERD_PID=""

if command -v dockerd-rootless.sh >/dev/null 2>&1; then
    log "Arrancando dockerd-rootless ENJAULADO..."
    # ─── JAULA DE MONTAJE del daemon (probada el 2026-09-04: JAULA-OK) ───────
    # Los -v de docker se resuelven en el namespace del DAEMON. Arrancandolo en
    # un namespace donde /shared y /home son tmpfs vacios y de /raid solo
    # existe la carpeta del usuario, un `docker run -v /:/host` muestra ESA
    # vista, no el nodo real. No es un permiso que deniega: es que no existe.
    # unshare esta vetado por AppArmor en Ubuntu 24.04; rootlesskit tiene
    # perfil propio y CAP_SYS_ADMIN dentro de su namespace: la jaula va ahi.
    # Flags de red = los que usa dockerd-rootless.sh en este nodo (output.log).
    export DOCKER_SOCK
    nohup rootlesskit \
        --state-dir="${XDG_RUNTIME_DIR}/dockerd-rootless" \
        --net=slirp4netns --mtu=65520 \
        --slirp4netns-sandbox=auto --slirp4netns-seccomp=auto \
        --disable-host-loopback --port-driver=builtin \
        --copy-up=/etc --copy-up=/run --propagation=rslave \
        sh -c '
            set -e
            mkdir -p /run/jaula-keep
            [ -d "/raid/dgx/$USER" ] && mount --bind "/raid/dgx/$USER" /run/jaula-keep
            mount -t tmpfs -o ro,size=64k,mode=755 tmpfs /shared
            mount -t tmpfs -o size=64k,mode=755 tmpfs /home
            mount -t tmpfs -o ro,size=64k,mode=755 tmpfs /raid
            # La carpeta del usuario se sirve como /home/$USER: LA MISMA ruta
            # que ve en su sesion (el --home del apptainer). Asi -v $HOME/...
            # funciona tal cual, y /raid NI EXISTE en el mundo del daemon.
            mkdir -p "/home/$USER"
            if mountpoint -q /run/jaula-keep; then
                mount --bind /run/jaula-keep "/home/$USER"
            fi
            export HOME="/home/$USER"
            # el wrapper detecta "estoy dentro" por esta variable (la exporta su
            # invocacion exterior antes de relanzarse via rootlesskit); sin ella
            # se cree el padre, ve uid 0 mapeado y aborta con "must be executed
            # as a non-privileged user". Con ella toma la rama hijo -> dockerd.
            export _DOCKERD_ROOTLESS_CHILD=1
            # dockerd-rootless.sh detecta ROOTLESSKIT_STATE_DIR y ejecuta
            # dockerd directamente, sin crear otro namespace.
            exec dockerd-rootless.sh \
                --host="unix://${DOCKER_SOCK}" \
                --data-root="${XDG_RUNTIME_DIR}/docker-data" \
                --exec-root="${XDG_RUNTIME_DIR}/docker-exec" \
                --dns=130.206.68.169 \
                --dns=130.206.68.166
        ' > "$DOCKERD_LOG" 2>&1 &
    DOCKERD_PID=$!
    for i in $(seq 1 30); do
        [ -S "$DOCKER_SOCK" ] && break
        sleep 0.5
    done
    if [ -S "$DOCKER_SOCK" ]; then
        log "dockerd-rootless OK · PID=${DOCKERD_PID} · socket=${DOCKER_SOCK}"
    else
        log "WARN: dockerd-rootless no levantó. Tail dockerd.log:"
        tail -20 "$DOCKERD_LOG" 2>/dev/null | sed 's/^/    /'
        DOCKERD_PID=""
    fi
else
    log "INFO: dockerd-rootless.sh no instalado. Docker no disponible esta sesión."
fi

# ─── Marcador de sesion: lo escribe el VIGILANTE del nodo ───────────────────
# ood-session-watcher.service (root) observa quien escucha en cada puerto y
# anota a su dueno REAL en /raid/ood-sessions. Este script YA NO lo escribe:
# cuando lo escribia el propio usuario en un directorio 1777, el marcador era
# una reclamacion falsificable (se podian sembrar puertos ajenos).

# ─── subuid/subgid filtrados al usuario ─────────────────────────────────────
SUBUID_FILTERED="${PWD}/subuid.filtered"
SUBGID_FILTERED="${PWD}/subgid.filtered"
grep "^${USER}:" /etc/subuid > "$SUBUID_FILTERED" 2>/dev/null || {
    log "WARN: usuario ${USER} no tiene entrada en /etc/subuid. dockerd-rootless puede fallar."
    touch "$SUBUID_FILTERED"
}
grep "^${USER}:" /etc/subgid > "$SUBGID_FILTERED" 2>/dev/null || {
    log "WARN: usuario ${USER} no tiene entrada en /etc/subgid."
    touch "$SUBGID_FILTERED"
}
chmod 644 "$SUBUID_FILTERED" "$SUBGID_FILTERED"

# ─── Cleanup al cerrar el job ───────────────────────────────────────────────
cleanup() {
    local rc=$?
    log "=== CLEANUP (rc=${rc}) ==="
    if [ -n "$DOCKERD_PID" ] && kill -0 "$DOCKERD_PID" 2>/dev/null; then
        log "Matando dockerd-rootless PID=${DOCKERD_PID}"
        kill -TERM "$DOCKERD_PID" 2>/dev/null
        for i in 1 2 3 4 5; do
            kill -0 "$DOCKERD_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$DOCKERD_PID" 2>/dev/null
    fi
    # runtime dir propio de la sesión: limpiarlo para no dejar data-root huérfano en /tmp
    rm -rf "$XDG_RUNTIME_DIR" 2>/dev/null
    log "=== vscode_dgx END (rc=${rc}) ==="
}
trap cleanup EXIT INT TERM HUP

# ─── BIND_PATHS mínimo (solo home filtrado + subuid + docker) ───────────────
# Eliminados tras pentest 2026-05-14:
#   /etc/slurm, /run/munge        — no se usa Slurm/munge desde el SIF
#   /scratch                      — DGX no usa scratch tradicional HPC
#   /shared                       — sin datasets DGX
#   /usr/share/Modules, /etc/modulefiles, /etc/profile.d — modules no usa
#   /usr/libexec (completo)       — sólo necesitamos /usr/libexec/docker
# NO se monta /home: el contenedor solo debe ver la carpeta de trabajo del DGX,
# que se monta como HOME via --home (mas abajo). Aqui, solo subuid/subgid para
# Docker rootless y, si arranca, el socket de docker.
BIND_PATHS="\
${SUBUID_FILTERED}:/etc/subuid:ro,\
${SUBGID_FILTERED}:/etc/subgid:ro"

if [ -S "$DOCKER_SOCK" ]; then
    BIND_PATHS="${BIND_PATHS},\
${DOCKER_SOCK}:/var/run/docker.sock,\
/usr/bin/docker:/usr/bin/docker:ro"
    [ -d /usr/libexec/docker ] && \
        BIND_PATHS="${BIND_PATHS},/usr/libexec/docker:/usr/libexec/docker:ro"
    export APPTAINERENV_DOCKER_HOST="unix:///var/run/docker.sock"
fi

log "BIND_PATHS minimal: ${BIND_PATHS}"

# ─── Comprobar imagen ───────────────────────────────────────────────────────
if [ ! -f "$APPTAINER_IMAGE" ]; then
  log "ERROR: No se encuentra la imagen Apptainer en $APPTAINER_IMAGE"
  exit 1
fi

# ─── Directorio de trabajo: FIJO ────────────────────────────────────────────
# NO se pregunta en el formulario, a proposito. El unico sitio donde estas
# sesiones deben escribir es la carpeta del usuario en el DGX
# (/raid/dgx/<usuario>, montada como ~/clusters/dgx). Dejarlo elegir permitia
# apuntar al home de la cabina -- que tiene poco espacio y no es para datos de
# trabajo -- y saltarse el diseno entero.
ls "${HOME}/clusters/dgx/" >/dev/null 2>&1 || true    # dispara el automount

# El symlink ~/clusters/dgx -> /work-dgx/<corto> es la fuente FIABLE del nombre:
# para alumnos $USER puede venir con @dominio y no casa con las carpetas, que se
# crearon con el nombre corto.
LINK_TGT="$(readlink "${HOME}/clusters/dgx" 2>/dev/null || true)"   # /work-dgx/<u>
SHORT="$(basename "${LINK_TGT}" 2>/dev/null)"
WORK_SRC="/raid/dgx/${SHORT}"                    # ruta REAL en el disco del nodo
[ -d "$WORK_SRC" ] || WORK_SRC="$(readlink -f "${HOME}/clusters/dgx" 2>/dev/null || true)"
if [[ -z "${SHORT}" || -z "${WORK_SRC}" || ! -d "${WORK_SRC}" ]]; then
  log "ERROR: no tienes carpeta de trabajo en el cluster (${HOME}/clusters/dgx)."
  log "       Pide al administrador que te la aprovisione."
  exit 1
fi
# El usuario ve su carpeta de trabajo como su HOME clasico: /home/<usuario>.
CONT_HOME="/home/${SHORT}"
WORK_DIR_REAL="${CONT_HOME}"

# Estado de code-server dentro de la carpeta (oculto, persiste en el RAID). Se
# crea con la ruta del HOST; code-server lo usa con la del contenedor.
CS_DATA_HOST="${WORK_SRC}/.code-server"
CS_DATA_CONT="${CONT_HOME}/.code-server"
mkdir -p "${CS_DATA_HOST}/extensions"

# ─── Forzar la carpeta de apertura ──────────────────────────────────────────
# code-server recuerda la ultima carpeta abierta en coder.json y, al pedir la
# URL sin ?folder=, REDIRIGE a ella ignorando la ruta que le pasamos por linea
# de comandos. Un usuario que abrio una vez su home se quedaba anclado ahi para
# siempre. Se reescribe en cada arranque para que la sesion empiece SIEMPRE en
# la carpeta del cluster.
printf '{\n  "query": {\n    "folder": "%s"\n  }\n}\n' "${CONT_HOME}" \
    > "${CS_DATA_HOST}/coder.json"

# ─── Auth code-server: password aleatorio per-sesión ───────────────────────
export PASSWORD="${password}"
export APPTAINERENV_PASSWORD="${password}"

# Prompt de las terminales: apptainer inyecta PS1='Apptainer> ' en el entorno y
# las terminales de code-server/jupyter lo heredan. Se sustituye por un prompt
# con el usuario (sin el sufijo de dominio de los alumnos) y el nodo.
# ─── GPU asignada, para que el usuario pueda usarla desde SU Docker ─────────
# Slurm asigna instancias MIG concretas. `docker run --gpus all` pide los 8
# dispositivos PADRE y el driver acaba negando el contexto CUDA: el usuario ve
# 8 GPUs y no puede usar NINGUNA, ni la suya. Hay que pedir la instancia por
# UUID. Se expone en $MIS_GPUS dentro de la sesion para que no tenga que
# averiguarlo a mano.
MIS_GPUS="$(nvidia-smi -L 2>/dev/null | grep -oE 'MIG-[0-9a-f-]+' | paste -sd, -)"
[ -z "$MIS_GPUS" ] && MIS_GPUS="$(nvidia-smi -L 2>/dev/null | grep -oE 'GPU-[0-9a-f-]+' | paste -sd, -)"
if [ -n "$MIS_GPUS" ]; then
    export APPTAINERENV_MIS_GPUS="$MIS_GPUS"
    log "GPU asignada (usar en docker --gpus): ${MIS_GPUS}"
else
    log "AVISO: no se detecto ninguna GPU asignada"
fi

export APPTAINERENV_PS1="${SHORT}@dgx:\\w\\$ "

log "WORK_DIR: ${WORK_DIR_REAL}"
log "Arrancando code-server en ${NODE_IP}:${port}..."

# ─── apptainer exec con namespaces aislados ─────────────────────────────────
# --pid: oculta procesos del host (cierra ptrace cross-namespace)
# --ipc: cierra SHM/signals compartidos
# --nv: pasa drivers/dispositivos NVIDIA al SIF
# --home monta la carpeta de trabajo en /home/<usuario> y lo fija como HOME;
# --pwd arranca ahi para que apptainer NO monte el cwd del job (el output dir de
# la NAS, que aparecia como /home/<u>/ondemand en solo-lectura).
apptainer exec \
  --pid \
  --ipc \
  --nv \
  --home "${WORK_SRC}:${CONT_HOME}" \
  --pwd "${CONT_HOME}" \
  --bind "$BIND_PATHS" \
  "$APPTAINER_IMAGE" \
  code-server \
    --bind-addr "${NODE_IP}:${port}" \
    --auth password \
    --disable-telemetry \
    --disable-update-check \
    --user-data-dir "${CS_DATA_CONT}" \
    --extensions-dir "${CS_DATA_CONT}/extensions" \
    "${CONT_HOME}" &

VSCODE_PID=$!
log "code-server PID=${VSCODE_PID}. Esperando exit..."

wait "${VSCODE_PID}"
VSCODE_RC=$?
log "code-server terminó con rc=${VSCODE_RC}"
exit $VSCODE_RC
