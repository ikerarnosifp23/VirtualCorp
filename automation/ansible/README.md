# Actividad 3 - Ansible y VPN WireGuard

Iker Arnosi - Delegación 03 (10.3.0.0/16)

## Cómo se usa

Todo se ejecuta desde `automation/ansible` en mi ordenador (el nodo de control):

```bash
ansible-playbook playbooks/start_routers.yml        # arrancar los 4 routers
ansible-playbook playbooks/stop_routers.yml         # apagarlos de forma ordenada
ansible-playbook playbooks/configure_wireguard.yml  # configurar la VPN
```

Antes hay que instalar Ansible, `wireguard-tools`, `python3-paramiko` y las colecciones:

```bash
ansible-galaxy collection install ansible.netcommon community.routeros
```

## Parte 1: arrancar y apagar los routers

- `inventories/lab.yml`: inventario con `localhost` (donde se ejecuta VBoxManage) y la lista de los 4 routers.
- `roles/start_vm`: mira el estado de la VM y solo la arranca si no está encendida.
- `roles/stop_vm`: si está encendida, manda el apagado ACPI y espera a que quede en `poweroff`.
- `playbooks/start_routers.yml` y `stop_routers.yml`: aplican el rol a cada router con un bucle.

Comprobación de idempotencia (cada playbook ejecutado dos veces):

| Ejecución | Resultado |
|---|---|
| Arrancar (1ª) | changed=4 |
| Arrancar (2ª) | changed=0, skipped=4 |
| Apagar (1ª) | changed=4 |
| Apagar (2ª) | changed=0, skipped=8 |

## Parte 2: VPN WireGuard

### Diseño

| Dato | Valor |
|---|---|
| Red del túnel | 10.3.10.0/24 (no choca con ninguna red de la delegación) |
| Servidor (mikrotik0, interfaz `wg-vcorp`) | 10.3.10.1/24 |
| Puerto UDP | 51820 |
| Cliente (`cliente1`) | 10.3.10.2/32 |
| Endpoint del cliente | 127.0.0.1:51820 |

Las variables están en `inventories/group_vars/all/wireguard.yml`, separadas de las tareas y sin ningún secreto.

### Redes autorizadas (AllowedIPs)

Es un **túnel dividido**: solo pasan por la VPN las redes de VirtualCorp que he autorizado. El resto (Internet) sale directo.

- `10.3.10.0/24`: el propio túnel.
- `10.3.0.128/26`: zona privada (pve01, dbsrv, infosrv).
- `10.3.0.224/28`: enlaces entre routers (rt0_1, rt1_2, rt2_3).

He elegido estas porque son las que hoy tienen equipos con IP. Las plantas todavía no tienen DHCP. Para dar acceso a otra red solo hay que añadirla a `wg_allowed_networks` y volver a ejecutar el playbook.

### Cómo funciona el playbook

`playbooks/configure_wireguard.yml` hace tres cosas, en este orden:

1. **Claves del cliente** (`roles/wireguard_client/tasks/keys.yml`): genera la clave privada con `wg genkey` y la pública con `wg pubkey`. Solo las crea si no existen. Se guardan en `artifacts/vpn/`, que Git ignora, con permisos 600.
2. **Servidor** (`roles/wireguard_server`): en mikrotik0 crea la interfaz, la dirección, el peer, la lista de redes y las reglas de firewall. Antes de crear cada cosa comprueba si ya existe, así que no se duplica nada. También crea el reenvío UDP de VirtualBox.
3. **Fichero del cliente** (`roles/wireguard_client/tasks/config.yml`): escribe `artifacts/vpn/cliente1.conf` con la clave pública que genera RouterOS.

Las tareas que leen o escriben claves privadas llevan `no_log: true`. Me conecto a mikrotik0 con `network_cli` y `community.routeros.command` (usuario `sysadmin+cet1024w`, que es `sysadmin` sin colores, como recomienda la colección).

### Reenvío UDP

mikrotik0 tiene la NIC1 en NAT de VirtualBox. He añadido la regla `vcorp-wg,udp,127.0.0.1,51820,,51820`, que reenvía el puerto UDP 51820 de mi ordenador al 51820 de mikrotik0. Escucha solo en 127.0.0.1, porque el cliente está en el mismo ordenador.

### Reglas de firewall añadidas en mikrotik0

| Regla | Qué hace |
|---|---|
| `vcorp-wg-input` | input: acepta UDP 51820 (WireGuard). Va al principio |
| `vcorp-wg-fwd-allow` | forward: lo que entra por `wg-vcorp` hacia la lista `vcorp-vpn-permitidas` se acepta |
| `vcorp-wg-fwd-drop` | forward: el resto de lo que entra por el túnel se descarta |

### Rutas de vuelta

No he puesto NAT entre el túnel y la red interna. La red 10.3.10.0/24 está conectada a mikrotik0 y RIP la anuncia sola (`redistribute=connected,rip`). He comprobado que mikrotik3 tiene la ruta `DAr 10.3.10.0/24` aprendida por RIP.

### Activar el túnel en el cliente

```bash
sudo install -m 600 artifacts/vpn/cliente1.conf /etc/wireguard/cliente1.conf
sudo wg-quick up cliente1
```

## Pruebas

Las salidas están en `docs/evidencias/vpn.txt`.

- **Playbook ejecutado dos veces:** la 2ª da `changed=0`, sin duplicados.
- **Handshake:** se hace, y se ve en `wg show` y en `/interface wireguard peers`.
- **Ping por la VPN:** responden 10.3.10.1, mikrotik0, mikrotik1, mikrotik2, mikrotik3 y pve01.
- **SSH a pve01 (10.3.0.133) por la VPN:** responde `pve01`.
- **Túnel dividido:** `1.1.1.1` y `10.3.1.1` (no autorizada) salen por mi tarjeta normal, no por `cliente1`.
- **Persistencia:** después de bajar y subir el túnel y reiniciar mikrotik0, la configuración sigue y el handshake vuelve a hacerse.

## Problemas

- **`wg-quick` no podía leer el `.conf` desde mi carpeta (Permission denied).** AppArmor de Ubuntu solo le deja leer `/etc/wireguard`. Lo copio ahí con permisos 600.
- **Ansible no leía bien las respuestas de RouterOS por los colores.** He usado el usuario `sysadmin+cet1024w`.
- **El primer ping a pve01 fallaba.** pve01 estaba apagado y tarda 1-2 minutos en arrancar.
