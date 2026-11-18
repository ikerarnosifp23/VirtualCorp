# Actividad 2 - Despliegue de los equipos

Iker Arnosi - Delegación 03 (10.3.0.0/16)

## Qué he hecho

En esta actividad he creado dos templates de Debian, he desplegado todos los equipos de la delegación clonando esos templates y he instalado Proxmox en pve01. Todo se hace con scripts y el Makefile, sin tocar nada a mano durante las instalaciones.

Para desplegarlo todo desde cero:

```bash
cp .env.example .env
make ssh-keys
make deploy-routers
make create_templates
make deploy_equipment
```

## Versiones de las ISO

Las versiones y las URL están en variables en el fichero `.env.example`. Así nunca se descarga otra versión sin querer:

- **Debian 13.7.0:** `debian-13.7.0-amd64-netinst.iso`, de cdimage.debian.org.
- **Proxmox VE 9.2-1:** `proxmox-ve_9.2-1.iso`, de enterprise.proxmox.com (en los problemas explico por qué).
- **Herramienta de Proxmox:** `proxmox-auto-install-assistant`, versión 9.2.9.

Cada vez que se descarga algo, el script comprueba la suma SHA256 para saber que el fichero está bien. Si quiero cambiar de versión, cambio la variable en una rama nueva, lo pruebo y después lo junto con main.

## Los templates (make create_templates)

He hecho dos templates:

- **tpl-debian-server:** sin entorno gráfico. Lo uso para los servidores (dbsrv, infosrv, websrv y los de los proyectos) y para las impresoras.
- **tpl-debian-desktop:** con LXQt y Falkon, sin Firefox ni ofimática. Lo uso para los PCs, la conserjería y los expositores.

La instalación es desatendida gracias a un fichero **preseed** (`configs/preseed/debian.preseed.template`) que tiene todas las respuestas del instalador. El script `create_templates.sh` rellena el preseed, crea la máquina, la instala y al final le hace un snapshot llamado `base`, que es el que se usa para clonar.

Lo que ya viene configurado en los templates:

- La IP se obtiene por DHCP.
- Existe el usuario `sysadmin`, con sudo.
- Están autorizadas la clave del profesor (`vcorp_auditor.pub`) y la mía (`vcorp_sysadmin.pub`).
- Por SSH solo se puede entrar con clave, no con contraseña.
- Al final de la instalación borro el machine-id y las claves SSH del host, para que cada clon genere las suyas y no sean todas iguales.


## Los equipos (make deploy_equipment)

Las máquinas están apuntadas en `configs/equipment.conf`, cada una con su template, su RAM y su red. El script `deploy_equipment.sh` las crea todas como **clones enlazados**: comparten el disco del template y por eso ocupan muy poco. Cada máquina tiene una sola tarjeta de red, en red interna. La única con NAT es mikrotik0, que es la salida a Internet.

| Red | Equipos | Router |
|---|---|---|
| privada | pve01, dbsrv, infosrv | mikrotik0 |
| dmz | websrv | mikrotik0 |
| pl0 | printer0, expo1-4, conserge1-2 | mikrotik1 |
| pl1 | printer1, p1web1, p1data1, p1web2, p1data2, dev1 | mikrotik2 |
| pl2 | printer2, p2web1, p2data1, dev2 | mikrotik2 |
| pl3 | printer3, dept1 | mikrotik3 |
| pl3_direccio | direccio1, direccio2, direccio3 | mikrotik3 |
| rt0_1, rt1_2, rt2_3 | solo los enlaces entre routers | - |

En vez de los 50 portátiles, he puesto un PC de ejemplo en cada planta (dev1, dev2 y dept1). Los demás cogerán IP por DHCP y se pueden añadir más tarde en el fichero sin cambiar el script.

## pve01 con Proxmox

pve01 no sale de ningún template. Lo instala el script `deploy_pve01.sh`, que también se lanza con `make deploy_equipment`. Para que la instalación sea desatendida uso un fichero `answer.toml` (`configs/proxmox/answer.toml.template`) y la herramienta `proxmox-auto-install-assistant`, que lo mete dentro de la ISO.

- **Recursos:** 4 CPU, 8 GB de RAM y 64 GB de disco.
- **Red:** privada, con IP fija 10.3.0.133/26 y puerta de enlace 10.3.0.129 (mikrotik0).
- **Disco:** ext4 con LVM-thin, sin ZFS.
- **Virtualización anidada:** activada en el script con `--nested-hw-virt on`.
- **Acceso:** la clave del profesor y la mía están en `root-ssh-keys`, así que se entra como root con clave.

## Comprobaciones

He guardado las salidas en `docs/evidencias/`:

- **maquinas.txt:** aparecen los 4 routers, los 2 templates, los 25 clones enlazados y pve01, cada uno en su grupo.
- **redes.txt:** cada máquina está en su red y solo mikrotik0 tiene NAT.

También he probado lo siguiente:

- **Un clon del Desktop:**
  - Entro por SSH sin contraseña.
  - Coge IP por DHCP.
  - Tiene LXQt y Falkon, y no tiene Firefox.
  - Aparece la pantalla de inicio de sesión.
- **pve01:**
  - Se llama pve01.vcorp.local, tiene la versión 9.2.2 y la IP correcta.
  - `/dev/kvm` existe y la CPU tiene vmx, así que la virtualización anidada funciona.
  - Hace ping a los 4 routers y a 1.1.1.1.
  - Tiene las dos claves.
- **Instalaciones:** ninguna me ha pedido nada durante el proceso.

## Problemas que he tenido

- **No podía descargar Proxmox de download.proxmox.com.** El servidor daba un certificado de otro dominio. Lo he cambiado a enterprise.proxmox.com, que es el que sale en la web oficial, y compruebo la suma SHA256.
- **No podía instalar la herramienta de Proxmox en Ubuntu.** El repositorio con HTTPS daba el mismo problema y el enterprise pide suscripción. Descargo el paquete por HTTP del repositorio gratuito, compruebo su SHA256 y lo descomprimo.
- **El template Desktop ocupaba 7,5 GB.** Debian instalaba muchos paquetes recomendados. Los he desactivado en el preseed y ha bajado a 2,7 GB.
- **Los clones salían en el grupo de templates.** `clonevm` no hacía caso de `--groups`, así que les pongo el grupo después con `modifyvm`.
- **`make ssh-keys` cambiaba la clave del profesor.** La he recuperado con `git restore`. Nunca subo claves privadas.
- **Nombres de las redes.** Los routers usaban otros nombres (r0-r1...). Los he cambiado a los del enunciado y he añadido la red privada a mikrotik0.
- **La clave del profesor.** En el enunciado pone `vcorp-auditor.pub`, pero en el repo se llama `vcorp_auditor.pub`. He usado la del repo sin cambiarla.
