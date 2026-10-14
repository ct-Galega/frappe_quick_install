# Frappe v16 — instalador de bench (`frappe_install_v16.sh`)

Instala **solo el bench** de Frappe v16 en un VPS limpio con **Debian 13+** o **Ubuntu 24.04+**
(Python 3.14, Node 24, MariaDB 11.8). **No crea sitios**, no instala ERPNext y no configura la
producción: eso se hace después a mano. Deja todo instalado y preparado para hacerlo.

## Qué hace

- MariaDB 11.8 (repo oficial firmado, solo si la distro no la trae), Redis
- wkhtmltopdf con Qt parcheado (checksum fijado)
- Node 24 (nvm), Python 3.14 y bench (uv), y `bench init`
- Crea el **usuario administrador de MariaDB** que elijas (por defecto `root`) con la contraseña que indiques
- Deja instalado lo que necesita la producción: nginx, supervisor, fail2ban, ansible-core, certbot y acl
- Deja preparado:
  - `bench`, `node`, `npm`, `yarn` en `~/.local/bin`, y el PATH en `~/.profile` y `~/.bashrc`
  - `/etc/sudoers.d/<usuario>-bench-path`: `sudo bench ...` funciona (añade `~/.local/bin` al final del `secure_path`)
  - `node` enlazado en `/usr/local/bin` para que supervisor lo vea (si no, socketio falla con `spawn error`)
  - ACL para que nginx (`www-data`) lea `apps` y `sites/assets` (si no, no carga el CSS) sin abrir el home a todos

## Qué pregunta

| Pregunta | Variable | Por defecto |
|---|---|---|
| Nombre del bench | `BENCH_NAME` | `frappe-bench` |
| Usuario administrador de MariaDB | `DB_ADMIN_USER` | `root` |
| Contraseña de ese usuario (mín. 12 caracteres, se pide dos veces) | `FRAPPE_DB_PASSWORD` | — |

Más una confirmación final. Otras variables: `ASSUME_YES=1` (sin confirmación), `FRAPPE_BRANCH`
(`version-16`), `ALLOW_UNSUPPORTED=1` (distro no probada), `NO_SHELL=1` (no abrir shell nueva).

Con `DB_ADMIN_USER=root` se añade contraseña al root de MariaDB sin quitar el acceso por socket.
Con otro nombre se crea ese usuario con todos los privilegios (`WITH GRANT OPTION`).
La contraseña se pasa a MariaDB por stdin y no se guarda en ningún fichero.

## Reglas básicas

- Ejecutar como **usuario normal con sudo** (no root, no `sudo bash ...`) y con **`bash`**, nunca con `source`.
- Si se ejecuta como root o con otro usuario, bench y nvm quedan en el home equivocado: empezar de nuevo.
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

No uses `su frappe` (hereda el entorno de root). Entra por SSH:

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

### 4. Descargar y ejecutar el script

```bash
cd ~ && mkdir -p frappe_quick_install && cd frappe_quick_install
# copia aquí frappe_install_v16.sh
bash frappe_install_v16.sh
```

Al terminar abre una shell nueva en la carpeta del bench con `bench` y `node` cargados. Si no se abrió:
`exec bash -l`.

### 5. Verificar

```bash
bench --version
node -v                  # v24.x
which bench node yarn
sudo bench --version     # sin "command not found"
```

## Después de la instalación

### Crear un sitio

```bash
cd ~/<bench>
bench new-site SITIO --db-root-username <DB_ADMIN_USER>
# pide la contraseña de MariaDB y la del Administrator
```

ERPNext (opcional):

```bash
bench get-app erpnext --branch version-16
bench --site SITIO install-app erpnext
```

Probar en desarrollo: `bench use SITIO && bench start` (http://IP:8000, Ctrl+C para salir).

### Poner en producción

```bash
cd ~/<bench>
# acceso de nginx a los ficheros públicos de los sitios creados
for d in sites/*/public; do
  sudo setfacl -R -m u:www-data:rX "$d"
  sudo setfacl -R -d -m u:www-data:rX "$d"
done
sudo bench setup production frappe --yes
```

Comprobar:

```bash
sudo supervisorctl status          # todo en RUNNING, incluido socketio
sudo nginx -t && sudo systemctl status nginx --no-pager
curl -I http://localhost
```

Con ufw: `sudo ufw allow 80/tcp && sudo ufw allow 443/tcp`.

### DNS y SSL

1. Crea el registro A del sitio apuntando a la IP del servidor.
2. Activa multitenancy DNS y regenera nginx:
   ```bash
   cd ~/<bench>
   bench config dns_multitenant on
   bench setup nginx --yes
   sudo systemctl reload nginx
   ```
3. Pide el certificado: `sudo -H bench setup lets-encrypt SITIO`
   (alternativa para un solo sitio: `sudo certbot --nginx -d SITIO`; comprueba `sudo certbot renew --dry-run`).

### Operación diaria

```bash
bench --site SITIO backup --with-files
bench --site SITIO migrate
bench update
sudo supervisorctl restart all
```

Logs: `~/<bench>/logs/` y `/var/log/nginx/`.

## Solución de problemas

| Síntoma | Causa y solución |
|---|---|
| `bench: command not found` | Shell sin el PATH cargado: `exec bash -l` |
| `sudo: bench: command not found` | Falta la regla de sudoers: vuelve a ejecutar el script, o usa `sudo env "PATH=$PATH" bench ...` |
| `Cannot start socketio: node not found` (en `bench start`) | nvm no cargado en la shell: `exec bash -l` |
| `Cannot start socketio: node not found` (supervisor, `spawn error`) | `sudo ln -sfn "$(readlink -f "$(command -v node)")" /usr/local/bin/node && sudo supervisorctl restart all` |
| MariaDB error 1698 (`Access denied for user 'root'@'localhost'`) | Usa `--db-root-username` y la contraseña que fijó el script |
| 502 en nginx | Revisa `sudo supervisorctl status` y `~/<bench>/logs/web.error.log` |
| Sin CSS ni imágenes | nginx no puede leer el bench. Comprueba `sudo -u www-data test -r ~/<bench>/sites/assets/frappe` y `/var/log/nginx/error.log`; repite los `setfacl` de arriba |

## Estado de las pruebas

La regla de sudoers se probó con `visudo` real y un sudo simulado; el resto del script se ha
comprobado con `bash -n` y shellcheck. La instalación completa (apt, `bench init`,
`bench setup production`, SSL y el repo de MariaDB 11.8) debe validarse en un VPS limpio.
