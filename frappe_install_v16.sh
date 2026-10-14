#!/usr/bin/env bash
#
# frappe_install_v16.sh — Frappe v16 (bench) en Debian 13+ o Ubuntu 24.04+
#
# Uso (como usuario NORMAL con sudo, nunca como root, y SIN "source"):
#   bash frappe_install_v16.sh
#
# Solo instala el bench. NO crea sitios, ni instala ERPNext, ni configura la
# producción: eso se hace después a mano (el resumen final dice cómo).
#
# Qué hace (sigue la guía oficial de instalación de Frappe para v16):
#   MariaDB 11.8 (repo oficial firmado solo si la distro no la trae), Redis,
#   wkhtmltopdf con Qt parcheado (checksum fijado), Node 24 (nvm), Python 3.14
#   y bench (uv), deja bench/nvm/node en el PATH (sesiones futuras, sudo y
#   supervisor) y hace bench init. Deja instalado y preparado lo que la
#   producción necesita: nginx, supervisor, fail2ban, ansible-core, certbot,
#   acl, y los permisos (ACL) para que nginx lea los ficheros públicos.
#
# Pregunta (si la variable no está definida): BENCH_NAME, DB_ADMIN_USER (usuario
# administrador de MariaDB, por defecto root) y su contraseña
# (FRAPPE_DB_PASSWORD), y pide confirmación final.
# Otras variables:
#   ASSUME_YES=1        omite la confirmación final
#   FRAPPE_BRANCH       (version-16)
#   ALLOW_UNSUPPORTED=1 distro/versión no probada
#   NO_SHELL=1          no abrir una shell nueva al terminar (por defecto, en un
#                       terminal, se abre una shell de login con bench y node)
#
# Contraseña: se pasa a MariaDB por stdin, nunca por la línea de comandos, y no
# se guarda en ningún fichero.

# --- No permitir "source": un exit/set -e mataría la sesión del usuario ------
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "No uses 'source'. Ejecuta: bash ${BASH_SOURCE[0]}" >&2
    return 1 2>/dev/null || exit 1
fi

set -Eeuo pipefail

# --- Configuración ------------------------------------------------------------
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-16}"
MARIADB_VERSION="${MARIADB_VERSION:-11.8}"
NODE_MAJOR="${NODE_MAJOR:-24}"
NVM_VERSION="${NVM_VERSION:-v0.40.3}"
PY_VERSION="${PY_VERSION:-3.14}"

# Huella de la clave de firma de MariaDB (publicada por MariaDB).
MARIADB_KEY_FPR="177F4010FE56CA3336300305F1656F24C74CD1D8"
MARIADB_KEY_URLS=(
    "https://mariadb.org/mariadb_release_signing_key.pgp"
    "https://supplychain.mariadb.com/mariadb-keyring-2019.gpg"
)

# wkhtmltopdf con Qt parcheado (Frappe lo necesita en v16 para los PDF).
# No hay paquetes para trixie ni noble: se usan los de bookworm y jammy.
WK_VERSION="0.12.6.1-3"
WK_BASE="https://github.com/wkhtmltopdf/packaging/releases/download/${WK_VERSION}"
declare -A WK_SHA256=(
    [bookworm_amd64]="98ba0d157b50d36f23bd0dedf4c0aa28c7b0c50fcdcdc54aa5b6bbba81a3941d"
    [bookworm_arm64]="b6606157b27c13e044d0abbe670301f88de4e1782afca4f9c06a5817f3e03a9c"
    [jammy_amd64]="4f723b2691ad8638a9df960e0421d346d7315083e3583a334f33362280ddba15"
    [jammy_arm64]="2095f20256661ebf0983b9311168596c9d012666e21a94bc24f304db6ac69ec5"
)

# --- Salida -------------------------------------------------------------------
if [[ -t 1 ]]; then
    Y=$'\033[1;33m'; G=$'\033[0;32m'; R=$'\033[0;31m'; B=$'\033[1;34m'; N=$'\033[0m'
else
    Y=""; G=""; R=""; B=""; N=""
fi
info() { printf '%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s✔ %s%s\n' "$G" "$*" "$N"; }
warn() { printf '%s! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%sERROR: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

on_err() { printf '%sFallo en la línea %s (código %s)%s\n' "$R" "$1" "$2" "$N" >&2; }
trap 'on_err "$LINENO" "$?"' ERR

WORKDIR="$(mktemp -d)"
KEEPALIVE_PID=""
cleanup() {
    [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- Utilidades ---------------------------------------------------------------
ask() { # ask VAR "pregunta" [defecto]
    local __var=$1 prompt=$2 default=${3:-} reply
    [[ -n "${!__var:-}" ]] && return 0
    if [[ ! -t 0 ]]; then
        [[ -n "$default" ]] || die "Falta ${__var} y no hay terminal interactivo: defínelo como variable de entorno."
        printf -v "$__var" '%s' "$default"
        return 0
    fi
    read -rp "${prompt}${default:+ [$default]}: " reply || reply=""
    printf -v "$__var" '%s' "${reply:-$default}"
}

flag() { # flag VAR : normaliza la variable a yes/no (sin preguntar; vacía = no)
    local __var=$1 v
    v=${!__var:-no}; v=${v,,}
    case "$v" in
        y|yes|s|si|sí|1|true) printf -v "$__var" '%s' yes ;;
        *)                    printf -v "$__var" '%s' no ;;
    esac
}

# yesno VAR "pregunta" y|n : si VAR ya viene definida, la usa sin preguntar;
# sin terminal interactivo toma el valor por defecto; si no, pregunta.
yesno() {
    local __var=$1 prompt=$2 default=${3:-n} reply hint
    if [[ -n "${!__var:-}" ]]; then flag "$__var"; return 0; fi
    if [[ ! -t 0 ]]; then printf -v "$__var" '%s' "$default"; flag "$__var"; return 0; fi
    [[ $default == y ]] && hint="S/n" || hint="s/N"
    read -rp "$prompt [$hint]: " reply || reply=""
    printf -v "$__var" '%s' "${reply:-$default}"
    flag "$__var"
}

# Pide confirmación antes de empezar (omitida sin terminal o con ASSUME_YES=1).
confirm_go() {
    [[ -t 0 && "${ASSUME_YES:-}" != 1 ]] || return 0
    local go=""
    yesno go "$1" y
    [[ $go == yes ]] || { info "Cancelado. No se ha cambiado nada."; exit 0; }
}

read_secret_twice() { # read_secret_twice VAR "pregunta"
    local __var=$1 prompt=$2 a b
    [[ -t 0 ]] || die "Hace falta un terminal interactivo para pedir la contraseña (o define FRAPPE_DB_PASSWORD)."
    while true; do
        read -rsp "$prompt: " a; echo
        read -rsp "Repite la contraseña: " b; echo
        [[ "$a" == "$b" ]] || { warn "No coinciden. Prueba otra vez."; continue; }
        [[ ${#a} -ge 12 ]] || { warn "Usa al menos 12 caracteres."; continue; }
        printf -v "$__var" '%s' "$a"
        return 0
    done
}

# Escapa una cadena para un literal SQL entre comillas simples (MariaDB).
sql_escape() {
    local s=$1 q="'" bs='\'
    # Entrecomillar el patrón: sin comillas, "\" actúa como escape y no casa.
    s=${s//"$bs"/"$bs$bs"}
    s=${s//"$q"/"$q$q"}
    printf '%s' "$s"
}

apt_install() { sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"; }

# --- Comprobaciones previas ---------------------------------------------------
preflight() {
    [[ $EUID -ne 0 ]] || die "No lo ejecutes como root. Crea un usuario con sudo (adduser frappe && usermod -aG sudo frappe) y entra con él."
    command -v sudo >/dev/null || die "Falta sudo. Como root: apt install sudo && usermod -aG sudo $(id -un)"
    [[ -r /etc/os-release ]] || die "No encuentro /etc/os-release."

    RUN_USER=$(id -un)
    OS_ID=$(. /etc/os-release; printf '%s' "${ID:-}")
    OS_VER=$(. /etc/os-release; printf '%s' "${VERSION_ID:-0}")
    OS_CODENAME=$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")

    local supported=no
    case "$OS_ID" in
        debian) dpkg --compare-versions "$OS_VER" ge 13 && supported=yes ;;
        ubuntu) dpkg --compare-versions "$OS_VER" ge 24.04 && supported=yes ;;
    esac
    if [[ $supported == no ]]; then
        [[ "${ALLOW_UNSUPPORTED:-}" == 1 ]] \
            || die "Solo Debian 13+ y Ubuntu 24.04+ (detectado: $OS_ID $OS_VER). Usa ALLOW_UNSUPPORTED=1 para continuar bajo tu responsabilidad."
        warn "Distro no soportada ($OS_ID $OS_VER): sigo porque ALLOW_UNSUPPORTED=1."
    fi

    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in amd64|arm64) ;; *) die "Arquitectura no soportada: $ARCH" ;; esac

    info "Necesito sudo durante la instalación..."
    sudo -v || die "No tienes permisos de sudo."
    ( while true; do sudo -n true 2>/dev/null || exit 0; sleep 50; kill -0 "$$" 2>/dev/null || exit 0; done ) &
    KEEPALIVE_PID=$!
}

# --- Datos de entrada ---------------------------------------------------------
collect_inputs() {
    # En un terminal, si un nombre no es válido se vuelve a preguntar.
    while true; do
        ask BENCH_NAME "Nombre del bench (carpeta en tu home)" "frappe-bench"
        [[ "$BENCH_NAME" =~ ^[A-Za-z0-9._-]+$ ]] && break
        [[ -t 0 ]] || die "Nombre de bench no válido: solo letras, números, '.', '_' y '-'."
        warn "Nombre de bench no válido: solo letras, números, '.', '_' y '-'."
        BENCH_NAME=""
    done

    while true; do
        ask DB_ADMIN_USER "Usuario administrador de MariaDB (el que usará 'bench new-site')" "root"
        [[ "$DB_ADMIN_USER" =~ ^[A-Za-z0-9_]{1,32}$ ]] && break
        [[ -t 0 ]] || die "Usuario de MariaDB no válido: solo letras, números y '_' (máx. 32)."
        warn "Usuario no válido: solo letras, números y '_' (máx. 32)."
        DB_ADMIN_USER=""
    done

    if [[ -z "${FRAPPE_DB_PASSWORD:-}" ]]; then
        echo "Contraseña de '$DB_ADMIN_USER' en MariaDB (mínimo 12 caracteres)."
        read_secret_twice DB_PASSWORD "Contraseña de MariaDB para '$DB_ADMIN_USER'"
    else
        DB_PASSWORD=$FRAPPE_DB_PASSWORD
        unset FRAPPE_DB_PASSWORD
    fi
}

# --- MariaDB ------------------------------------------------------------------
setup_mariadb_repo() {
    sudo apt-get update
    local cand
    cand=$(apt-cache policy mariadb-server 2>/dev/null | awk '/Candidate:/ {print $2}')
    if [[ "${cand#*:}" == "${MARIADB_VERSION}".* ]]; then
        ok "La distro ya trae MariaDB ${MARIADB_VERSION} (${cand}); no añado repositorios."
        return 0
    fi

    info "La distro trae MariaDB ${cand:-ninguna}; añado el repositorio oficial ${MARIADB_VERSION} con clave verificada."
    apt_install ca-certificates curl gnupg
    [[ -n "$OS_CODENAME" ]] || die "No pude determinar el codename de la distro."

    local keyfile="$WORKDIR/mariadb.key" url got=no
    for url in "${MARIADB_KEY_URLS[@]}"; do
        if curl -fsSL "$url" -o "$keyfile" 2>/dev/null; then got=yes; break; fi
    done
    [[ $got == yes ]] || die "No pude descargar la clave de firma de MariaDB."
    gpg --show-keys --with-colons "$keyfile" | awk -F: '/^fpr:/ {print $10}' | grep -qx "$MARIADB_KEY_FPR" \
        || die "La clave descargada NO coincide con la huella esperada de MariaDB. Abortando."

    sudo install -d -m 0755 /etc/apt/keyrings
    if grep -q 'BEGIN PGP' "$keyfile"; then
        gpg --dearmor < "$keyfile" | sudo tee /etc/apt/keyrings/mariadb-keyring.gpg >/dev/null
    else
        sudo install -m 0644 "$keyfile" /etc/apt/keyrings/mariadb-keyring.gpg
    fi
    sudo chmod 0644 /etc/apt/keyrings/mariadb-keyring.gpg

    if [[ -f /etc/apt/sources.list.d/mariadb.list ]]; then
        warn "Existe /etc/apt/sources.list.d/mariadb.list (¿de una instalación anterior?). Revísalo: puede tener 'trusted=yes'."
    fi
    sudo tee /etc/apt/sources.list.d/mariadb.sources >/dev/null <<EOF
Types: deb
URIs: https://deb.mariadb.org/${MARIADB_VERSION}/${OS_ID}
Suites: ${OS_CODENAME}
Components: main
Signed-By: /etc/apt/keyrings/mariadb-keyring.gpg
EOF
    sudo apt-get update
}

# Todo lo que 'bench setup production' necesita, instalado ya. Con estos
# binarios presentes, bench no intenta 'pip install ansible' (falla con bench
# instalado por uv). Solo se instalan: la configuración de nginx/supervisor la
# hace 'sudo bench setup production' cuando tú quieras.
PROD_PACKAGES=(nginx supervisor fail2ban ansible-core acl certbot)

install_packages() {
    info "Instalando paquetes del sistema (incluye los de producción)..."
    # redis-server: si la distro no lo trae, mejor parar que improvisar.
    local redis_cand
    redis_cand=$(apt-cache policy redis-server 2>/dev/null | awk '/Candidate:/ {print $2}')
    [[ -n "$redis_cand" && "$redis_cand" != "(none)" ]] \
        || die "No hay paquete redis-server en esta distro. Instala Redis/Valkey a mano y vuelve a ejecutar."

    apt_install git curl ca-certificates gnupg build-essential pkg-config cron \
        redis-server mariadb-server mariadb-client libmariadb-dev \
        fontconfig libxrender1 xfonts-75dpi xfonts-base xvfb libfontconfig \
        "${PROD_PACKAGES[@]}"
}

install_wkhtmltopdf() {
    if command -v wkhtmltopdf >/dev/null && wkhtmltopdf --version 2>/dev/null | grep -q 'patched qt'; then
        ok "wkhtmltopdf con Qt parcheado ya instalado."
        return 0
    fi
    local flavor deb key dir
    [[ "$OS_ID" == ubuntu ]] && flavor=jammy || flavor=bookworm
    key="${flavor}_${ARCH}"
    deb="wkhtmltox_${WK_VERSION}.${flavor}_${ARCH}.deb"
    info "Instalando wkhtmltopdf (${deb}, checksum verificado)..."
    dir="$WORKDIR/wk"; mkdir -p "$dir"
    curl -fsSL "${WK_BASE}/${deb}" -o "$dir/$deb"
    echo "${WK_SHA256[$key]}  $dir/$deb" | sha256sum -c - >/dev/null \
        || die "El checksum de ${deb} no coincide. Abortando."
    chmod 0755 "$dir"; chmod 0644 "$dir/$deb"
    apt_install "$dir/$deb"
    wkhtmltopdf --version | grep -q 'patched qt' \
        || warn "wkhtmltopdf instalado, pero no informa 'patched qt'. Revisa los PDF de Frappe."
}

configure_mariadb() {
    info "Configurando MariaDB (utf8mb4 y usuario administrador '$DB_ADMIN_USER')..."
    local confdir=/etc/mysql/mariadb.conf.d
    [[ -d $confdir ]] || confdir=/etc/mysql/conf.d
    sudo install -d -m 0755 "$confdir"
    sudo tee "$confdir/99-frappe.cnf" >/dev/null <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
EOF
    sudo systemctl enable --now mariadb
    sudo systemctl restart mariadb

    if MYSQL_PWD="$DB_PASSWORD" mariadb -u "$DB_ADMIN_USER" -e 'SELECT 1' >/dev/null 2>&1; then
        ok "'$DB_ADMIN_USER' ya entra en MariaDB con esa contraseña."
        return 0
    fi

    # La contraseña viaja por stdin, no por argv.
    local esc
    esc=$(sql_escape "$DB_PASSWORD")
    if [[ "$DB_ADMIN_USER" == root ]]; then
        # El root de MariaDB usa unix_socket: solo entra el root del SO. Se añade
        # contraseña (sin quitar el socket) para que 'bench new-site' pueda entrar
        # como usuario normal.
        sudo mariadb <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${esc}');
FLUSH PRIVILEGES;
SQL
    else
        sudo mariadb <<SQL
CREATE USER IF NOT EXISTS '${DB_ADMIN_USER}'@'localhost' IDENTIFIED BY '${esc}';
ALTER USER '${DB_ADMIN_USER}'@'localhost' IDENTIFIED BY '${esc}';
GRANT ALL PRIVILEGES ON *.* TO '${DB_ADMIN_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
    fi
    MYSQL_PWD="$DB_PASSWORD" mariadb -u "$DB_ADMIN_USER" -e 'SELECT 1' >/dev/null 2>&1 \
        || die "No pude verificar el login de '$DB_ADMIN_USER' en MariaDB con contraseña."
    ok "Usuario administrador '$DB_ADMIN_USER' de MariaDB listo."
}

# --- Node, Python, bench ------------------------------------------------------
install_node() {
    info "Instalando Node ${NODE_MAJOR} con nvm ${NVM_VERSION}..."
    export NVM_DIR="$HOME/.nvm"
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
        curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o "$WORKDIR/nvm-install.sh"
        bash "$WORKDIR/nvm-install.sh"
    fi
    # nvm no es compatible con 'set -eu' ni con el trap ERR.
    trap - ERR
    set +eu
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    nvm install "$NODE_MAJOR"
    nvm alias default "$NODE_MAJOR" >/dev/null
    nvm use "$NODE_MAJOR" >/dev/null
    set -eu
    trap 'on_err "$LINENO" "$?"' ERR

    command -v node >/dev/null || die "Node no quedó en el PATH."
    [[ "$(node -v | sed 's/^v//; s/\..*//')" == "$NODE_MAJOR" ]] || die "Node no es la versión ${NODE_MAJOR}: $(node -v)"
    command -v yarn >/dev/null || npm install -g yarn
    ok "Node $(node -v), yarn $(yarn -v)"
}

# nvm solo existe en las shells que lo cargan. Enlazar node/npm/npx/yarn en
# ~/.local/bin (que ya está en el PATH por bench) hace que bench start, bench
# build y yarn funcionen en cualquier sesión, aunque nvm no esté cargado.
link_node_tools() {
    mkdir -p "$HOME/.local/bin"
    local t src dst linked=()
    for t in node npm npx yarn; do
        src=$(command -v "$t" 2>/dev/null || true)
        dst="$HOME/.local/bin/$t"
        [[ -n "$src" && "$src" != "$dst" ]] || continue
        if [[ -e "$dst" && ! -L "$dst" ]]; then
            warn "$dst ya existe y no es un enlace: no lo toco."
            continue
        fi
        ln -sfn "$src" "$dst"
        linked+=("$t")
    done
    [[ ${#linked[@]} -eq 0 ]] || ok "Enlazados en ~/.local/bin: ${linked[*]} (funcionan aunque nvm no esté cargado)"
}

install_python_and_bench() {
    info "Instalando uv, Python ${PY_VERSION} y bench..."
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v uv >/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh -o "$WORKDIR/uv-install.sh"
        sh "$WORKDIR/uv-install.sh"
        export PATH="$HOME/.local/bin:$PATH"
    fi
    uv python install "$PY_VERSION"
    PYBIN=$(uv python find "$PY_VERSION")
    [[ -x "$PYBIN" ]] || die "No encuentro el intérprete de Python ${PY_VERSION}."
    command -v bench >/dev/null || uv tool install frappe-bench
    ok "bench $(bench --version), Python en ${PYBIN}"
}

# Un script no puede cambiar el PATH de la shell que lo lanzó, pero sí dejar
# las sesiones futuras bien configuradas (uv instala bench en ~/.local/bin).
persist_path() {
    info "Dejando bench y node en el PATH de las próximas sesiones..."
    local marker="# >>> frappe_install_v16 >>>" end="# <<< frappe_install_v16 <<<" f
    for f in "$HOME/.profile" "$HOME/.bashrc"; do
        touch "$f"
        if grep -qF "$marker" "$f"; then
            continue
        fi
        {
            printf '\n%s\n' "$marker"
            printf '%s\n' 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
            if ! grep -q 'nvm\.sh' "$f"; then
                printf '%s\n' 'export NVM_DIR="$HOME/.nvm"' '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
            fi
            printf '%s\n' "$end"
        } >> "$f"
    done
    ok "PATH persistente en ~/.profile y ~/.bashrc"
}

# 'sudo bench ...' falla con "command not found" porque sudo usa su propio PATH
# (secure_path) y no ve ~/.local/bin. No es solo cosmético: 'bench setup
# production' ejecuta which("node") bajo sudo, y sin node visible omite el
# programa de socketio de supervisor/systemd en silencio (sin tiempo real).
# Se añade ~/.local/bin AL FINAL del secure_path de este usuario: lo del sistema
# siempre tiene prioridad, así que no puede tapar comandos como apt o ls.
setup_sudo_path() {
    local dir="${SUDOERS_DIR:-/etc/sudoers.d}"
    if [[ ! -d "$dir" ]] || ! command -v visudo >/dev/null; then
        warn "No puedo configurar el PATH de sudo (falta $dir o visudo). Usa: sudo env \"PATH=\$PATH\" bench ..."
        return 0
    fi
    local cur tmp file="$dir/${RUN_USER}-bench-path"
    cur=$(sudo sh -c 'printf %s "$PATH"') || true
    if [[ -z "$cur" ]]; then
        warn "No pude leer el PATH de sudo; no toco la configuración. Usa: sudo env \"PATH=\$PATH\" bench ..."
        return 0
    fi
    case ":$cur:" in
        *":$HOME/.local/bin:"*) ok "sudo ya ve ~/.local/bin (sudo bench funciona)."; return 0 ;;
    esac
    tmp="$WORKDIR/sudo-path"
    printf 'Defaults:%s secure_path="%s:%s/.local/bin"\n' "$RUN_USER" "$cur" "$HOME" > "$tmp"
    if visudo -cf "$tmp" >/dev/null 2>&1; then
        sudo install -m 0440 "$tmp" "$file"
        ok "sudo ve ahora ~/.local/bin (al final de su PATH): 'sudo bench ...' y node funcionan. Regla: $file"
    else
        warn "visudo rechazó la regla; no la instalo. Usa: sudo env \"PATH=\$PATH\" bench ..."
    fi
}

init_bench() {
    BENCH_DIR="$HOME/$BENCH_NAME"
    if [[ -d "$BENCH_DIR/apps/frappe" ]]; then
        warn "Ya existe $BENCH_DIR: lo reutilizo."
        return 0
    fi
    info "bench init ($FRAPPE_BRANCH)... esto tarda unos minutos."
    cd "$HOME"
    bench init "$BENCH_NAME" --frappe-branch "$FRAPPE_BRANCH" --python "$PYBIN" --verbose
}

# --- Preparación para producción ----------------------------------------------
grant_nginx_access() {
    # nginx sirve /assets y /files desde dentro de tu home. En vez de abrir el
    # home a todo el mundo (chmod -R o+rx), se da acceso solo al usuario de
    # nginx y solo a lo público; sites/<sitio>/private y site_config.json NO.
    local ng_user
    ng_user=$(awk '$1=="user" {gsub(/;/,"",$2); print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null || true)
    ng_user=${ng_user:-www-data}
    id "$ng_user" >/dev/null 2>&1 || die "No existe el usuario de nginx '$ng_user'."
    NGINX_USER=$ng_user

    info "Dando a '$ng_user' acceso de solo lectura a los ficheros públicos (ACL)..."
    sudo setfacl -m "u:${ng_user}:x" "$HOME" "$BENCH_DIR" "$BENCH_DIR/sites"
    # Los sitios que se creen después heredan el permiso de paso (x) en su carpeta.
    sudo setfacl -d -m "u:${ng_user}:x" "$BENCH_DIR/sites"
    local d
    for d in "$BENCH_DIR/apps" "$BENCH_DIR/sites/assets"; do
        [[ -d "$d" ]] || continue
        sudo setfacl -R -m "u:${ng_user}:rX" "$d"
        sudo setfacl -R -d -m "u:${ng_user}:rX" "$d"
    done
}

link_node_system() {
    # supervisor arranca los procesos con el PATH del sistema (sin ~/.local/bin
    # ni nvm): sin esto, socketio falla con "node not found" (spawn error).
    local node dst=/usr/local/bin/node
    node=$(readlink -f "$(command -v node 2>/dev/null)" 2>/dev/null || true)
    [[ -n "$node" && -x "$node" ]] || { warn "No encuentro node: socketio no arrancará en producción."; return 0; }
    if [[ -e "$dst" && ! -L "$dst" ]]; then
        warn "$dst ya existe y no es un enlace: no lo toco."
        return 0
    fi
    sudo ln -sfn "$node" "$dst"
    ok "node visible para supervisor: $dst -> $node"
}

summary() {
    echo
    ok "Instalación terminada."
    echo "  Bench:               $BENCH_DIR"
    echo "  Admin de MariaDB:    $DB_ADMIN_USER"
    echo
    echo "  Siguientes pasos (no se ha creado ningún sitio):"
    echo "    cd $BENCH_DIR"
    echo "    bench new-site SITIO --db-root-username $DB_ADMIN_USER     # pide la contraseña de MariaDB y la del Administrator"
    echo "    bench get-app erpnext --branch $FRAPPE_BRANCH && bench --site SITIO install-app erpnext    # opcional"
    echo "    bench use SITIO && bench start                             # desarrollo"
    echo
    echo "  Producción (ya está todo instalado y los permisos preparados):"
    echo "    for d in sites/*/public; do sudo setfacl -R -m u:${NGINX_USER:-www-data}:rX \"\$d\"; sudo setfacl -R -d -m u:${NGINX_USER:-www-data}:rX \"\$d\"; done"
    echo "    sudo bench setup production $RUN_USER --yes"
    echo "  (la primera línea da a nginx acceso a los ficheros públicos de los sitios creados)"
    echo "  Firewall (no lo toco por si te dejara fuera). Si usas ufw:"
    echo "    sudo ufw allow OpenSSH && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw enable"
    echo
    if will_open_shell; then
        echo "  Al terminar se abre una shell nueva (en $BENCH_DIR) con bench y node ya cargados."
        echo "  Escribe 'exit' para volver a la anterior. Las sesiones SSH nuevas ya los llevan."
    else
        echo "  Para tener bench y node en ESTA terminal ahora mismo:  exec bash -l"
        echo "  (las sesiones nuevas ya los llevan en el PATH)."
    fi
    echo "  La contraseña de MariaDB no se guarda en ningún fichero de este script."
}

# Un script no puede cambiar el PATH de la terminal que lo lanzó. Lo más cercano
# a "automático": sustituir el proceso del script por una shell de login nueva,
# que lee ~/.profile (PATH + nvm) y deja al usuario en la carpeta del bench.
will_open_shell() { [[ -t 0 && -t 1 && "${NO_SHELL:-}" != 1 ]]; }

enter_fresh_shell() {
    will_open_shell || return 0
    local dir=${1:-$HOME}
    [[ -d "$dir" ]] || dir=$HOME
    echo
    info "Abriendo una shell nueva con bench y node cargados (escribe 'exit' para volver a la anterior)..."
    # 'exec' no ejecuta el trap EXIT: limpiar a mano (temporales y el proceso
    # que mantenía vivo sudo, que de otro modo seguiría con el PID de la shell).
    cleanup
    trap - EXIT ERR
    cd "$dir"
    exec bash -l
}

# Resumen de lo elegido y confirmación antes de tocar el sistema.
confirm_plan() {
    echo
    info "Resumen de lo que se va a hacer"
    echo "  Usuario:      $RUN_USER   ($OS_ID $OS_VER, $ARCH)"
    echo "  Frappe:       $FRAPPE_BRANCH en ~/$BENCH_NAME (sin sitios)"
    echo "  MariaDB:      usuario administrador '$DB_ADMIN_USER'"
    echo "  Versiones:    MariaDB $MARIADB_VERSION, Node $NODE_MAJOR, Python $PY_VERSION"
    echo "  Sistema:      instala paquetes con sudo (también nginx, supervisor, fail2ban, certbot)"
    echo "                y prepara permisos para producción; NO configura producción"
    confirm_go "¿Continuar con la instalación?"
}

main() {
    [[ $# -eq 0 ]] || die "Uso: bash $0   (sin argumentos)"
    preflight
    collect_inputs
    confirm_plan
    setup_mariadb_repo
    install_packages
    install_wkhtmltopdf
    configure_mariadb
    install_node
    link_node_tools
    install_python_and_bench
    # Justo tras instalar bench (no al final): así queda hecho aunque un paso
    # posterior falle.
    persist_path
    setup_sudo_path
    init_bench
    grant_nginx_access
    link_node_system
    summary
    enter_fresh_shell "$BENCH_DIR"
}

main "$@"
