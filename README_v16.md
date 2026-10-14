# Frappe / ERPNext v16 — instalador (`frappe_install_v16.sh`)

Instala Frappe v16 (y opcionalmente ERPNext) en un VPS limpio con **Debian 13+** o **Ubuntu 24.04+**.
Solo contempla la versión 16 (Python 3.14, Node 24, MariaDB 11.8).

## Qué instala

- MariaDB 11.8 (repo oficial firmado, solo si la distro no la trae), Redis
- wkhtmltopdf con Qt parcheado (checksum fijado)
- Node 24 (nvm), Python 3.14 y bench (uv)
- `bench init` y creación del sitio
- Siempre deja instalado lo necesario para producción: nginx, supervisor, fail2ban, ansible-core, certbot y acl.
  Configurarlo es opcional, ahora o después con el modo `production`.

## Reglas básicas

- Ejecutar como **usuario normal con sudo** (no root, no `sudo bash ...`).
- Ejecutar con **`bash`**, nunca con `source`.
- Si se ejecuta como root o con otro usuario, bench y nvm quedan en el home equivocado: empezar de nuevo en un VPS limpio.
- No mezclar con el script antiguo ni con `pip3 install frappe-bench` en el mismo servidor.

## Instalación paso a paso

### 1. Crear el usuario `frappe` (una vez, como root)

```bash
adduser --gecos "" frappe
usermod -aG sudo frappe
```

Para entrar por SSH con clave:

```bash
mkdir -p /home/frappe/.ssh
cp ~/.ssh/authorized_keys /home/frappe/.ssh/
chown -R frappe:frappe /home/frappe/.ssh
chmod 700 /home/frappe/.ssh && chmod 600 /home/frappe/.ssh/authorized_keys
```

### 2. Entrar como `frappe` con una sesión real

No uses `su frappe` (hereda el entorno de root). Sal y entra por SSH:

```bash
ssh frappe@IP-del-servidor
whoami          # frappe
echo $HOME      # /home/frappe
```

### 3. Actualizar el sistema

```bash
sudo apt update && sudo apt full-upgrade -y
[ -f /var/run/reboot-required ] && sudo reboot
```

### 4. Descargar el script

```bash
cd ~
mkdir -p frappe_quick_install && cd frappe_quick_install
# copia aquí frappe_install_v16.sh
```

### 5. Ejecutarlo

```bash
bash frappe_install_v16.sh               # interactivo: menú y preguntas
bash frappe_install_v16.sh install       # directo a la instalación base
bash frappe_install_v16.sh production    # directo a configurar producción
```

Se pregunta (si la variable no está definida): nombre del bench, nombre del sitio, contraseña de root de MariaDB,
instalar ERPNext, configurar producción y SSL (respuesta por defecto: no), y una confirmación final.

Variables para saltarse preguntas o ajustar el comportamiento:

| Variable | Efecto |
|---|---|
| `BENCH_NAME`, `SITE_NAME` | Nombre del bench y del sitio |
| `FRAPPE_DB_ROOT_PASSWORD` | Contraseña de root de MariaDB |
| `INSTALL_ERPNEXT`, `SETUP_PRODUCTION`, `SETUP_SSL` | `yes`/`no` |
| `ASSUME_YES=1` | Omite la confirmación final |
| `FRAPPE_BRANCH` | Rama de Frappe (por defecto `version-16`) |
| `ALLOW_UNSUPPORTED=1` | Permite una distro o versión no probada |
| `NO_SHELL=1` | No abre una shell nueva al terminar |

Ejemplo sin preguntas:

```bash
ASSUME_YES=1 FRAPPE_DB_ROOT_PASSWORD='...' bash frappe_install_v16.sh install
```

Sin terminal interactivo (cron, CI) no pregunta nada: usa solo las variables.

## Qué hace el script con el PATH y sudo

Un script no puede cambiar el `PATH` de la terminal que lo lanzó. Por eso:

- Añade un bloque con el `PATH` y nvm a `~/.profile` y `~/.bashrc`.
- Enlaza `node`, `npm`, `npx` y `yarn` en `~/.local/bin`.
- Enlaza `node` en `/usr/local/bin` para que supervisor lo vea (si no, socketio falla con `spawn error`).
- Da a nginx acceso de solo lectura (ACL) a `apps`, `sites/assets` y `public`, para que cargue el CSS aunque la producción se configure después a mano.
- Crea `/etc/sudoers.d/<usuario>-bench-path`, que añade `~/.local/bin` al final del `secure_path` de sudo
  (validado con `visudo`). Así funcionan `sudo bench ...` y `node` bajo sudo (necesario para socketio en producción).
- Al terminar abre una shell de login nueva en la carpeta del bench. Si no se abrió, ejecuta `exec bash -l`.

## Después de la instalación

### Verificar

```bash
exec bash -l                        # solo si no se abrió la shell nueva
bench --version
node -v                             # v24.x
which bench node yarn
sudo bench --version                # sin "command not found"
cd ~/<bench> && bench --site <sitio> list-apps
```

### Probar en modo desarrollo (opcional)

```bash
cd ~/<bench>
bench start                         # http://IP:8000, Ctrl+C para salir
```

### Poner en producción

```bash
bash ~/frappe_quick_install/frappe_install_v16.sh production
# o a mano:
cd ~/<bench> && sudo bench setup production frappe --yes
```

Comprobar:

```bash
sudo supervisorctl status           # todo en RUNNING
sudo nginx -t && sudo systemctl status nginx --no-pager
curl -I http://localhost
```

Con ufw, abrir los puertos:

```bash
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
```

### DNS y SSL

1. Crea el registro A del sitio apuntando a la IP del servidor.
2. Activa multitenancy DNS y regenera nginx:
   ```bash
   cd ~/<bench>
   bench config dns_multitenant on
   bench setup nginx --yes
   sudo systemctl reload nginx
   ```
3. Pide el certificado:
   ```bash
   sudo bench setup lets-encrypt <sitio>
   ```
   Alternativa para un solo sitio: `sudo certbot --nginx -d <sitio>`. Comprueba que no choque con la
   configuración que genera bench y que la renovación funcione (`sudo certbot renew --dry-run`).

### ERPNext (si no se instaló con el script)

```bash
cd ~/<bench>
bench get-app erpnext --branch version-16
bench --site <sitio> install-app erpnext
sudo supervisorctl restart all
```

### Operación diaria

```bash
bench --site <sitio> backup --with-files
bench --site <sitio> migrate
bench update
sudo supervisorctl restart all
```

Logs: `~/<bench>/logs/` y `/var/log/nginx/`.

## Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| `bench: command not found` | Shell sin el PATH cargado: `exec bash -l` |
| `sudo: bench: command not found` | Falta la regla de sudoers: ejecuta `bash frappe_install_v16.sh production` o usa `sudo env "PATH=$PATH" bench ...` |
| `Cannot start socketio: node not found` (en `bench start`) | nvm no cargado en la shell: `exec bash -l` |
| `Cannot start socketio: node not found` (supervisor, `spawn error`) | supervisor no ve node: `sudo ln -sfn "$(readlink -f "$(command -v node)")" /usr/local/bin/node && sudo supervisorctl restart all` (el script ya lo hace) |
| MariaDB error 1698 (`Access denied for user 'root'@'localhost'`) | root usa unix_socket; el script deja contraseña de root, usa `--db-root-password` |
| 502 en nginx | Revisa `sudo supervisorctl status` y `~/<bench>/logs/web.error.log` |
| Sin CSS ni imágenes | nginx (`www-data`) no puede leer el bench. El script da acceso por ACL; si falta, repite `bash frappe_install_v16.sh production` o `sudo setfacl` (ver el script, `grant_nginx_access`). Comprueba con `sudo -u www-data test -r ~/<bench>/sites/assets/frappe` y `/var/log/nginx/error.log` |

## Estado de las pruebas

La regla de sudoers se probó con `visudo` real y un sudo simulado. La instalación completa
(apt, `bench init`, `bench setup production`, SSL y el repo de MariaDB 11.8) debe validarse en un VPS limpio.
