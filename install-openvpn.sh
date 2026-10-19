#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# OpenVPN Docker - instalação limpa Ubuntu
# ============================================================

# ---------- Variáveis principais ----------
OVPN_IMAGE="lisenet/openvpn:2.6.11-build27"
OVPN_DATA="ovpn-data"
CONTAINER_NAME="openvpn"
OVPN_HOST="vpn.example.com"
OVPN_PORT="1194"
VPN_SUBNET="172.27.255.0/24"
CLIENT_NAME="notebook"
DNS1="8.8.8.8"
DNS2="8.8.4.4"
MSSFIX="1372"
EXTERNAL_IFACE=""                 # vazio = detectar automaticamente
NAT_SERVICE="openvpn-nat.service"


usage() {
  cat <<'EOF'
Uso:
  sudo bash install-openvpn.sh
  sudo bash install-openvpn.sh --add-client NOME
  sudo bash install-openvpn.sh --help

--add-client cria um certificado e NOME.ovpn usando o container e volume
existentes, sem executar novamente a instalação.
EOF
}
valid_client_name() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

MODE="install"
ADD_CLIENT=""
case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  --add-client)
    [[ $# -eq 2 ]] || { echo "Uso: $0 --add-client NOME" >&2; exit 2; }
    valid_client_name "$2" || { echo "ERRO: nome de cliente inválido." >&2; exit 2; }
    MODE="add-client"
    ADD_CLIENT="$2"
    ;;
  "") ;;
  *) echo "ERRO: argumento desconhecido: $1 (use --help)." >&2; exit 2 ;;
esac

log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die(){ echo "ERRO: $*" >&2; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || die "Execute como root ou com sudo."; }

check_ubuntu(){
  [[ -r /etc/os-release ]] || die "/etc/os-release não encontrado."
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Este script requer Ubuntu. Detectado: ${ID:-desconhecido}."
  case "${VERSION_ID:-}" in 22.04|24.04|26.04) ;; *) die "Ubuntu suportado: 22.04, 24.04 ou 26.04. Detectado: ${VERSION_ID:-desconhecido}.";; esac
}

validate_vars(){
  [[ "$OVPN_PORT" =~ ^[0-9]+$ ]] || die "OVPN_PORT inválida."
  [[ "$MSSFIX" =~ ^[0-9]+$ ]] || die "MSSFIX inválido."
  [[ "$CLIENT_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "CLIENT_NAME inválido."
}

detect_iface(){
  if [[ -z "$EXTERNAL_IFACE" ]]; then
    EXTERNAL_IFACE="$(ip route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
  fi
  [[ -n "$EXTERNAL_IFACE" ]] || die "Não foi possível detectar a interface externa."
}

install_docker(){
  if command -v docker >/dev/null 2>&1; then
    log "Docker já instalado: $(docker --version)"
    systemctl enable --now docker
    return
  fi

  log "Instalando Docker Engine pelo repositório oficial..."
  apt-get update
  apt-get install -y ca-certificates curl iptables

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  . /etc/os-release
  cat >/etc/apt/sources.list.d/docker.sources <<EOT
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOT

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker info >/dev/null 2>&1 || die "Docker Engine não iniciou."
}

configure_forwarding(){
  log "Habilitando IPv4 forwarding..."
  cat >/etc/sysctl.d/99-openvpn.conf <<'EOT'
net.ipv4.ip_forward=1
EOT
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

check_clean_state(){
  if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    die "Container $CONTAINER_NAME já existe. Remova-o manualmente se deseja uma instalação limpa."
  fi
  if docker volume inspect "$OVPN_DATA" >/dev/null 2>&1; then
    die "Volume $OVPN_DATA já existe. Remova-o manualmente se deseja uma instalação limpa; isso apagará a PKI."
  fi
}

create_volume(){
  log "Criando volume $OVPN_DATA..."
  docker volume create "$OVPN_DATA" >/dev/null
}

generate_config(){
  log "Gerando configuração OpenVPN..."
  docker run --rm -v "$OVPN_DATA:/etc/openvpn" "$OVPN_IMAGE" \
    ovpn_genconfig \
    -u "udp://${OVPN_HOST}:${OVPN_PORT}" \
    -s "$VPN_SUBNET" \
    -n "$DNS1" -n "$DNS2"
}

configure_server(){
  local mount conf env
  mount="$(docker volume inspect "$OVPN_DATA" --format '{{.Mountpoint}}')"
  conf="$mount/openvpn.conf"
  env="$mount/ovpn_env.sh"
  [[ -f "$conf" && -f "$env" ]] || die "Configuração OpenVPN incompleta."

  log "Configurando mssfix ${MSSFIX} mtu..."
  sed -i -E '/^[[:space:]]*mssfix[[:space:]]+/d' "$conf"
  printf '\nmssfix %s mtu\n' "$MSSFIX" >> "$conf"

  ! grep -q '192\.168\.254\.0/24' "$conf" "$env" || die "Configuração contém a rede antiga 192.168.254.0/24."
  grep -q "^server ${VPN_SUBNET%/*} " "$conf" || die "A rede VPN gerada não corresponde a VPN_SUBNET=$VPN_SUBNET."
}

initialize_pki(){
  log "Inicializando PKI..."
  echo "Será solicitada a senha da CA. Guarde-a em local seguro."
  docker run --rm -it -v "$OVPN_DATA:/etc/openvpn" "$OVPN_IMAGE" ovpn_initpki
}

start_server(){
  log "Iniciando container OpenVPN com correção iptables-nft..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -v "$OVPN_DATA:/etc/openvpn" \
    -p "${OVPN_PORT}:1194/udp" \
    --cap-add=NET_ADMIN \
    --entrypoint /bin/sh \
    "$OVPN_IMAGE" \
    -c 'ln -sf /sbin/iptables-nft /sbin/iptables &&
        ln -sf /sbin/iptables-nft /sbin/iptables-save &&
        ln -sf /sbin/iptables-nft /sbin/iptables-restore &&
        if [ -x /sbin/ip6tables-nft ]; then
          ln -sf /sbin/ip6tables-nft /sbin/ip6tables
          ln -sf /sbin/ip6tables-nft /sbin/ip6tables-save
          ln -sf /sbin/ip6tables-nft /sbin/ip6tables-restore
        fi
        find / -type f -name easyrsa -exec sed -i \
          -e "s/~VER~/container-packaged/g" \
          -e "s/~DATE~/metadata-unavailable/g" \
          -e "s/~GITHEAD~/metadata-unavailable/g" {} + 2>/dev/null || true
        exec ovpn_run' >/dev/null

  sleep 3
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" == true ]] || {
    docker logs --tail 100 "$CONTAINER_NAME" || true
    die "Container OpenVPN não iniciou."
  }
  [[ "$(docker exec "$CONTAINER_NAME" iptables -V 2>/dev/null)" == *nf_tables* ]] ||
    die "O container não está usando iptables-nft."
}

configure_nat(){
  log "Configurando NAT..."
  # NAT explícito no host; a regra é persistida por systemd.
  if ! iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$EXTERNAL_IFACE" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o "$EXTERNAL_IFACE" -j MASQUERADE
  fi

  # Permite forwarding específico se o host tiver FORWARD=DROP.
  # As regras são instaladas em DOCKER-USER, que é o ponto recomendado
  # para regras próprias quando Docker gerencia o firewall.
  for chain in DOCKER-USER; do
    iptables -nL "$chain" >/dev/null 2>&1 || die "Chain $chain não existe após iniciar Docker."
  done

  if ! iptables -C DOCKER-USER -s "$VPN_SUBNET" -j ACCEPT 2>/dev/null; then
    iptables -I DOCKER-USER 1 -s "$VPN_SUBNET" -j ACCEPT
  fi
  if ! iptables -C DOCKER-USER -d "$VPN_SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    iptables -I DOCKER-USER 1 -d "$VPN_SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  fi
}

install_nat_persistence(){
  log "Criando serviço para persistir NAT após reboot..."
  cat >"/etc/systemd/system/$NAT_SERVICE" <<EOT
[Unit]
Description=OpenVPN Docker NAT rules
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/openvpn-nat.sh
ExecStop=/usr/local/sbin/openvpn-nat-remove.sh

[Install]
WantedBy=multi-user.target
EOT

  cat >/usr/local/sbin/openvpn-nat.sh <<EOT
#!/usr/bin/env bash
set -e
iptables -t nat -C POSTROUTING -s '$VPN_SUBNET' -o '$EXTERNAL_IFACE' -j MASQUERADE 2>/dev/null || \\
iptables -t nat -A POSTROUTING -s '$VPN_SUBNET' -o '$EXTERNAL_IFACE' -j MASQUERADE
iptables -C DOCKER-USER -s '$VPN_SUBNET' -j ACCEPT 2>/dev/null || \\
iptables -I DOCKER-USER 1 -s '$VPN_SUBNET' -j ACCEPT
iptables -C DOCKER-USER -d '$VPN_SUBNET' -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \\
iptables -I DOCKER-USER 1 -d '$VPN_SUBNET' -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
EOT

  cat >/usr/local/sbin/openvpn-nat-remove.sh <<EOT
#!/usr/bin/env bash
set +e
iptables -t nat -D POSTROUTING -s '$VPN_SUBNET' -o '$EXTERNAL_IFACE' -j MASQUERADE 2>/dev/null
iptables -D DOCKER-USER -s '$VPN_SUBNET' -j ACCEPT 2>/dev/null
iptables -D DOCKER-USER -d '$VPN_SUBNET' -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
EOT

  chmod 0755 /usr/local/sbin/openvpn-nat.sh /usr/local/sbin/openvpn-nat-remove.sh
  systemctl daemon-reload
  systemctl enable --now "$NAT_SERVICE"
}

generate_client(){
  local name="${1:-$CLIENT_NAME}" tmp output
  valid_client_name "$name" || die "Nome de cliente inválido."
  docker info >/dev/null 2>&1 || die "Docker não está respondendo."
  docker volume inspect "$OVPN_DATA" >/dev/null 2>&1 || die "Volume $OVPN_DATA não existe."
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || die "Container $CONTAINER_NAME não existe."
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")" == true ]] || die "Container $CONTAINER_NAME não está em execução."
  docker exec "$CONTAINER_NAME" test -s /etc/openvpn/pki/ca.crt || die "PKI/CA não encontrada."

  # Corrige apenas os metadados não expandidos do banner EasyRSA na imagem.
  # Isso não altera certificados/chaves; evita imprimir ~VER~, ~DATE~ e ~GITHEAD~.
  docker exec "$CONTAINER_NAME" sh -c 'find / -type f -name easyrsa -exec sed -i \
    -e "s/~VER~/container-packaged/g" \
    -e "s/~DATE~/metadata-unavailable/g" \
    -e "s/~GITHEAD~/metadata-unavailable/g" {} + 2>/dev/null || true'

  output="$PWD/${name}.ovpn"
  tmp="$(mktemp "$PWD/.${name}.ovpn.tmp.XXXXXX")"
  chmod 600 "$tmp"

  if docker exec "$CONTAINER_NAME" test -s "/etc/openvpn/pki/issued/${name}.crt"; then
    log "Certificado existente para $name; será reutilizado."
  else
    log "Gerando certificado do cliente $name..."
    if ! docker exec -it "$CONTAINER_NAME" easyrsa build-client-full "$name" nopass; then
      rm -f "$tmp"
      die "Falha ao criar certificado. O perfil final não foi alterado. Verifique a mensagem do EasyRSA."
    fi
  fi

  docker exec "$CONTAINER_NAME" test -s "/etc/openvpn/pki/issued/${name}.crt" ||
    { rm -f "$tmp"; die "Certificado de $name não foi criado."; }
  docker exec "$CONTAINER_NAME" test -s "/etc/openvpn/pki/private/${name}.key" ||
    { rm -f "$tmp"; die "Chave privada de $name não foi criada."; }

  log "Exportando perfil do cliente..."
  if ! docker exec "$CONTAINER_NAME" ovpn_getclient "$name" >"$tmp"; then
    rm -f "$tmp"
    die "ovpn_getclient falhou; o arquivo final não foi alterado."
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "Perfil vazio; arquivo final não foi alterado."; }
  grep -q 'BEGIN CERTIFICATE' "$tmp" || { rm -f "$tmp"; die "Perfil sem certificado; arquivo final não foi alterado."; }
  grep -q 'redirect-gateway def1' "$tmp" || { rm -f "$tmp"; die "Perfil sem redirect-gateway def1; arquivo final não foi alterado."; }

  mv -f "$tmp" "$output"
  chmod 600 "$output"
  log "Perfil criado: $output"
  log "Proteja o arquivo: contém a chave privada do cliente."
}

validate(){
  local mount conf env
  mount="$(docker volume inspect "$OVPN_DATA" --format '{{.Mountpoint}}')"
  conf="$mount/openvpn.conf"
  env="$mount/ovpn_env.sh"
  log "Validação final..."
  grep -E '^(server|mssfix|push "dhcp-option DNS|compress|comp-lzo|route )' "$conf" || true
  echo
  grep -E '^(declare -x OVPN_(SERVER|ROUTES|SERVER_URL))' "$env" || true
  echo
  docker exec "$CONTAINER_NAME" ip addr show tun0
  echo
  docker exec "$CONTAINER_NAME" iptables -t nat -L POSTROUTING -n -v
  echo
  iptables -t nat -L POSTROUTING -n -v | grep -E 'MASQUERADE|172\.27\.255' || true
  echo
  grep -E '^(remote |redirect-gateway|dhcp-option DNS|mssfix|compress|comp-lzo)' "${CLIENT_NAME}.ovpn" || true
}

main(){
  require_root
  check_ubuntu
  validate_vars
  detect_iface
  install_docker
  configure_forwarding
  check_clean_state
  create_volume
  generate_config
  configure_server
  initialize_pki
  start_server
  configure_nat
  install_nat_persistence
  generate_client "$CLIENT_NAME"
  validate

  echo
  echo '============================================================'
  echo 'OPENVPN INSTALADO COM SUCESSO'
  echo '============================================================'
  echo "Imagem:        $OVPN_IMAGE"
  echo "VPN subnet:    $VPN_SUBNET"
  echo "Endpoint:      udp://${OVPN_HOST}:${OVPN_PORT}"
  echo "WAN:           $EXTERNAL_IFACE"
  echo "MSSFIX:        ${MSSFIX} mtu"
  echo "Cliente:       $PWD/${CLIENT_NAME}.ovpn"
  echo
  echo 'Logs: docker logs --tail 100 openvpn'
  echo 'NAT:  systemctl status openvpn-nat.service'
}

if [[ "$MODE" == "add-client" ]]; then
  require_root
  generate_client "$ADD_CLIENT"
  exit 0
fi

main
