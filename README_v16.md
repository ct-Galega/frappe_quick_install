# Frappe v16 — preparación del servidor (`frappe_install_v16.sh`)

Prepara un VPS limpio con **Debian 13+** o **Ubuntu 24.04+** para Frappe v16
(Python 3.14, Node 24, MariaDB 11.8). **No crea ningún bench ni sitio**: el bench lo creas tú
después con `bench init`, en la rama que quieras (`version-16`, `version-16-hotfix`, `develop`...).

## Qué hace

- MariaDB 11.8 (repo oficial firmado, solo si la distro no la trae), Redis
- wkhtmltopdf con Qt parcheado (checksum fijado)
- Node 24 (nvm), Python 3.14 y el comando `bench` (uv)
- Crea el **usuario administrador de MariaDB** que elijas (por defecto `root`) con la contraseña que indiques
- Deja instalado lo que necesita la producción: nginx, supervisor, fail2ban, ansible-core, certbot y acl
- Deja preparado:
  - `bench`, `node`, `npm`, `yarn` en `~/.local/bin`, y el PATH en `~/.profile` y `~/.bashrc`
  - `/etc/sudoers.d/<usuario>-bench-path`: `sudo bench ...` funciona (añade `~/.local/bin` al final del `secure_path`)
  - `node` enlazado en `/usr/local/bin` para que supervisor lo vea (si no, socketio falla con `spawn error`)
  - nginx (`www-data`) puede atravesar tu home (ACL `x`, sin listar ni leer su contenido), para que
    pueda servir `sites/assets` y `/files` del bench sin abrir el home a todos

## Qué pregunta

| Pregunta | Variable | Por defecto |
|---|---|---|
| Usuario administrador de MariaDB | `DB_ADMIN_USER` | `root` |
| Contraseña de ese usuario (mín. 12 caracteres, se pide dos veces) | `FRAPPE_DB_PASSWORD` | — |

Más una confirmación final. Otras variables: `ASSUME_YES=1` (sin confirmación),
`ALLOW_UNSUPPORTED=1` (distro no probada), `NO_SHELL=1` (no abrir shell nueva).

Con `DB_ADMIN_USER=root` se añade contraseña al root de MariaDB sin quitar el acceso por socket.
Con otro nombre se crea ese usuario con todos los privilegios (`WITH GRANT OPTION`).
La contraseña se pasa a MariaDB por stdin y no se guarda en ningún fichero.

## Reglas básicas

- Ejecutar como **usuario normal con sudo** (no root, no `sudo bash ...`) y con **`bash`**, nunca con `source`.
- Si se ejecuta como root o con otro usuario, nvm y bench quedan en el home equivocado: empezar de nuevo.
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

El script termina con el servidor listo pero sin bench. Los pasos son:

### 1. Crear el bench (elige la rama)

```bash
bench init --frappe-branch version-16 --python "$(uv python find 3.14)" --verbose NOMBRE
```

Otras ramas: `--frappe-branch version-16-hotfix` o `--frappe-branch develop`
(`develop` puede pedir otras versiones de Python o Node que las de este script).

### 2. Crear el sitio

```bash
cd ~/NOMBRE
bench new-site SITIO --db-root-username <DB_ADMIN_USER>
# pide la contraseña de MariaDB y la del Administrator
```

Usa un FQDN como nombre del sitio (p. ej. `erp.midominio.es`) si vas a usar SSL.

### 3. Activar multitenancy DNS y poner en producción

```bash
bench config dns_multitenant on
sudo bench setup production frappe --yes
```

Comprobar:

```bash
sudo supervisorctl status          # todo en RUNNING, incluido socketio
sudo nginx -t && sudo systemctl status nginx --no-pager
curl -I http://localhost
```

Con ufw: `sudo ufw allow 80/tcp && sudo ufw allow 443/tcp`.

### Opcionales

- **ERPNext:** `bench get-app erpnext --branch version-16 && bench --site SITIO install-app erpnext`
  (antes de poner en producción, o reinicia con `sudo supervisorctl restart all`).
- **SSL:** con el DNS apuntando al servidor y el puerto 80 abierto: `sudo -H bench setup lets-encrypt SITIO`
  (alternativa para un solo sitio: `sudo certbot --nginx -d SITIO`; comprueba `sudo certbot renew --dry-run`).
- **Ficheros públicos subidos (`/files`) dan 403:** da a nginx lectura sobre la carpeta pública del sitio:
  ```bash
  cd ~/<bench>
  for d in sites/*/public; do
    sudo setfacl -R -m u:www-data:rX "$d"
    sudo setfacl -R -d -m u:www-data:rX "$d"
  done
  ```

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
| Sin CSS ni imágenes | nginx no puede leer el bench. Comprueba `sudo -u www-data test -r ~/<bench>/sites/assets/frappe` y `/var/log/nginx/error.log`; comprueba que nginx entra en el home (`getfacl ~ | grep www-data`) y los permisos del bench (`namei -l ~/<bench>/sites/assets/frappe`) |

## Estado de las pruebas

La regla de sudoers se probó con `visudo` real y un sudo simulado; el resto del script se ha
comprobado con `bash -n` y shellcheck. La instalación completa (apt, `bench init`,
`bench setup production`, SSL y el repo de MariaDB 11.8) debe validarse en un VPS limpio.
