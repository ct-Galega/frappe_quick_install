#!/usr/bin/env bash
#
# frappe_install_v16.sh — Frappe / ERPNext v16 en Debian 13+ o Ubuntu 24.04+
#
# Uso (como usuario NORMAL con sudo, nunca como root, y SIN "source"):
#   bash frappe_install_v16.sh
#
# Qué hace (sigue la guía oficial de instalación de Frappe para v16):
#   MariaDB 11.8 (repo oficial firmado solo si la distro no la trae), Redis,
#   wkhtmltopdf con Qt parcheado (checksum fijado), Node 24 (nvm), Python 3.14
#   y bench (uv), bench init, sitio, ERPNext opcional y producción opcional
#   (nginx + supervisor + fail2ban + SSL con Let's Encrypt).
#
# Variables opcionales (se preguntan si no están definidas):
#   BENCH_NAME  SITE_NAME  FRAPPE_BRANCH (version-16)  INSTALL_ERPNEXT=yes|no
#   SETUP_PRODUCTION=yes|no  SETUP_SSL=yes|no  FRAPPE_DB_ROOT_PASSWORD
#   ALLOW_UNSUPPORTED=1   (continuar en una distro/versión no probada)
#
# Contraseñas: la de root de MariaDB se pide aquí (oculta) y se pasa a MariaDB
# por stdin, nunca por la línea de comandos. La del Administrator del sitio y
# la de root de MariaDB para "bench new-site" las pide el propio bench.

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
    read -rp "${prompt}${default:+ [$default]}: " reply
    printf -v "$__var" '%s' "${reply:-$default}"
}

yesno() { # yesno VAR "pregunta" y|n
    local __var=$1 prompt=$2 default=${3:-n} reply hint
    reply=${!__var:-}
    if [[ -z "$reply" ]]; then
        [[ "$default" == y ]] && hint="S/n" || hint="s/N"
        read -rp "$prompt [$hint]: " reply
        reply=${reply:-$default}
    fi
    case "${reply,,}" in
        y|yes|s|si|sí|1|true) printf -v "$__var" '%s' yes ;;
        *)                    printf -v "$__var" '%s' no ;;
    esac
}

read_secret_twice() { # read_secret_twice VAR "pregunta"
    local __var=$1 prompt=$2 a b
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
    ask BENCH_NAME "Nombre del bench (carpeta en tu home)" "frappe-bench"
    [[ "$BENCH_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Nombre de bench no válido: solo letras, números, '.', '_' y '-'."

    ask SITE_NAME "Nombre del sitio (FQDN si vas a usar SSL, p. ej. erp.midominio.es)"
    SITE_NAME=${SITE_NAME,,}
    [[ "$SITE_NAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "Nombre de sitio no válido."

    yesno INSTALL_ERPNEXT "¿Instalar ERPNext en el sitio?" y
    yesno SETUP_PRODUCTION "¿Configurar producción (nginx + supervisor + fail2ban)?" y
    SETUP_SSL=${SETUP_SSL:-no}
    if [[ $SETUP_PRODUCTION == yes ]]; then
        yesno SETUP_SSL "¿Pedir certificado SSL de Let's Encrypt? (el DNS debe apuntar ya a este servidor y el puerto 80 estar abierto)" n
    fi

    if [[ -z "${FRAPPE_DB_ROOT_PASSWORD:-}" ]]; then
        echo "Contraseña de root de MariaDB (se fijará ahora; mínimo 12 caracteres)."
        read_secret_twice DB_ROOT_PASSWORD "Contraseña de root de MariaDB"
    else
        DB_ROOT_PASSWORD=$FRAPPE_DB_ROOT_PASSWORD
        unset FRAPPE_DB_ROOT_PASSWORD
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

install_packages() {
    info "Instalando paquetes del sistema..."
    # redis-server: si la distro no lo trae, mejor parar que improvisar.
    local redis_cand
    redis_cand=$(apt-cache policy redis-server 2>/dev/null | awk '/Candidate:/ {print $2}')
    [[ -n "$redis_cand" && "$redis_cand" != "(none)" ]] \
        || die "No hay paquete redis-server en esta distro. Instala Redis/Valkey a mano y vuelve a ejecutar."

    apt_install git curl ca-certificates gnupg build-essential pkg-config cron acl \
        redis-server mariadb-server mariadb-client libmariadb-dev \
        fontconfig libxrender1 xfonts-75dpi xfonts-base xvfb libfontconfig
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
    info "Configurando MariaDB (utf8mb4 y contraseña de root)..."
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

    if MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb -u root -e 'SELECT 1' >/dev/null 2>&1; then
        ok "root de MariaDB ya acepta esa contraseña."
        return 0
    fi

    # El root de MariaDB usa unix_socket: solo entra el root del SO. Se añade
    # contraseña (sin quitar el socket) para que 'bench new-site' pueda entrar
    # como usuario normal. La contraseña viaja por stdin, no por argv.
    local esc
    esc=$(sql_escape "$DB_ROOT_PASSWORD")
    sudo mariadb <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${esc}');
FLUSH PRIVILEGES;
SQL
    MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb -u root -e 'SELECT 1' >/dev/null 2>&1 \
        || die "No pude verificar el login de root de MariaDB con contraseña."
    ok "Contraseña de root de MariaDB establecida."
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

create_site() {
    cd "$BENCH_DIR"
    if [[ -d "sites/$SITE_NAME" ]]; then
        warn "El sitio $SITE_NAME ya existe: no lo recreo."
    else
        info "Creando el sitio $SITE_NAME."
        echo "bench te va a preguntar: superusuario de MySQL (pulsa Enter para 'root'),"
        echo "la contraseña de root de MariaDB (la que acabas de fijar) y la del Administrator."
        bench new-site "$SITE_NAME"
    fi
    bench use "$SITE_NAME"

    if [[ $INSTALL_ERPNEXT == yes ]]; then
        if [[ -d apps/erpnext ]]; then
            warn "erpnext ya está descargada."
        else
            bench get-app erpnext --branch "$FRAPPE_BRANCH"
        fi
        bench --site "$SITE_NAME" install-app erpnext
    fi
}

# --- Producción ---------------------------------------------------------------
grant_nginx_access() {
    # nginx sirve /assets y /files desde dentro de tu home. En vez de abrir el
    # home a todo el mundo (chmod -R o+rx), se da acceso solo al usuario de
    # nginx y solo a lo público; sites/<sitio>/private y site_config.json NO.
    local ng_user
    ng_user=$(awk '$1=="user" {gsub(/;/,"",$2); print $2; exit}' /etc/nginx/nginx.conf 2>/dev/null || true)
    ng_user=${ng_user:-www-data}
    id "$ng_user" >/dev/null 2>&1 || die "No existe el usuario de nginx '$ng_user'."

    info "Dando a '$ng_user' acceso de solo lectura a los ficheros públicos (ACL)..."
    mkdir -p "$BENCH_DIR/sites/$SITE_NAME/public/files"
    sudo setfacl -m "u:${ng_user}:x" "$HOME" "$BENCH_DIR" "$BENCH_DIR/sites" "$BENCH_DIR/sites/$SITE_NAME"
    local d
    for d in "$BENCH_DIR/apps" "$BENCH_DIR/sites/assets" "$BENCH_DIR/sites/$SITE_NAME/public"; do
        [[ -d "$d" ]] || continue
        sudo setfacl -R -m "u:${ng_user}:rX" "$d"
        sudo setfacl -R -d -m "u:${ng_user}:rX" "$d"
    done
}

setup_production() {
    info "Instalando nginx, supervisor, fail2ban y ansible-core..."
    # Con estos binarios ya presentes, 'bench setup production' no intenta
    # 'pip install ansible' (que falla con bench instalado por uv) ni lanzar
    # sus roles de ansible.
    apt_install nginx supervisor fail2ban ansible-core
    grant_nginx_access

    cd "$BENCH_DIR"
    info "bench setup production..."
    sudo env "PATH=$PATH:/usr/sbin:/sbin" bench setup production "$RUN_USER" --yes
    bench --site "$SITE_NAME" scheduler enable || true
    bench --site "$SITE_NAME" scheduler resume || true
    sudo supervisorctl status || true

    if [[ $SETUP_SSL == yes ]]; then
        info "Configurando SSL con Let's Encrypt (parará nginx unos segundos)."
        apt_install certbot
        bench config dns_multitenant on
        sudo -H env "PATH=$PATH:/usr/sbin:/sbin" bench setup lets-encrypt "$SITE_NAME"
    fi
}

summary() {
    echo
    ok "Instalación terminada."
    echo "  Bench:  $BENCH_DIR"
    echo "  Sitio:  $SITE_NAME"
    if [[ $SETUP_PRODUCTION == yes ]]; then
        if [[ $SETUP_SSL == yes ]]; then
            echo "  URL:    https://$SITE_NAME"
        else
            echo "  URL:    http://$SITE_NAME   (o la IP del servidor si el DNS aún no apunta)"
        fi
        echo
        echo "  Firewall (no lo toco por si te dejara fuera). Si usas ufw:"
        echo "     sudo ufw allow OpenSSH && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw enable"
    else
        echo "  Arranca el entorno de desarrollo con: cd $BENCH_DIR && bench start"
    fi
    echo
    echo "  Abre una terminal nueva (o 'source ~/.bashrc') para tener nvm y bench en el PATH."
    echo "  Contraseñas: no se guardan en ningún fichero de este script."
}

main() {
    preflight
    collect_inputs
    setup_mariadb_repo
    install_packages
    install_wkhtmltopdf
    configure_mariadb
    install_node
    install_python_and_bench
    init_bench
    create_site
    if [[ $SETUP_PRODUCTION == yes ]]; then
        setup_production
    fi
    summary
}

main "$@"
