#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="$HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
BACKUP_DIR="$HOME/.ssh-manager/backups"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_BACKUP="$BACKUP_DIR/sshd_config.backup"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$SSH_DIR" "$BACKUP_DIR"
chmod 700 "$SSH_DIR"

log_success() { echo -e "${GREEN}[✓] $1${NC}"; }
log_error()   { echo -e "${RED}[✗] $1${NC}"; }
log_info()    { echo -e "${CYAN}[i] $1${NC}"; }
log_warn()    { echo -e "${YELLOW}[!] $1${NC}"; }

cleanup() {
    if [[ -f "$AUTH_KEYS.tmp" ]]; then rm -f "$AUTH_KEYS.tmp"; fi
}
trap cleanup EXIT

require_sudo() {
    if [[ $EUID -ne 0 ]]; then
        log_info "Requesting sudo privileges..."
        sudo -v || { log_error "Sudo required for this operation."; exit 1; }
    fi
}

backup_sshd_config() {
    if [[ ! -f "$SSHD_CONFIG_BACKUP" ]]; then
        sudo cp "$SSHD_CONFIG" "$SSHD_CONFIG_BACKUP"
        log_success "Original sshd_config backed up to $SSHD_CONFIG_BACKUP"
    fi
}

fix_permissions() {
    chmod 700 "$SSH_DIR"
    if [[ -f "$AUTH_KEYS" ]]; then chmod 600 "$AUTH_KEYS"; fi
}

restart_ssh() {
    log_info "Restarting SSH service..."
    if systemctl is-active --quiet ssh; then
        sudo systemctl restart ssh
    elif systemctl is-active --quiet sshd; then
        sudo systemctl restart sshd
    else
        sudo service ssh restart 2>/dev/null || sudo service sshd restart 2>/dev/null || true
    fi
    log_success "SSH service restarted"
}

add_public_key() {
    local key_source="$1"
    local key_content=""
    if [[ -f "$key_source" ]]; then
        key_content=$(tr -d '\r' < "$key_source")
    else
        key_content=$(echo "$key_source" | tr -d '\r')
    fi

    if ! echo "$key_content" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|ssh-dss)'; then
        log_error "Invalid SSH public key format."
        return 1
    fi

    fix_permissions
    touch "$AUTH_KEYS"
    if grep -Fq "$key_content" "$AUTH_KEYS"; then
        log_warn "This public key is already in authorized_keys."
        return 0
    fi

    echo "$key_content" >> "$AUTH_KEYS"
    fix_permissions
    log_success "Public key added to $AUTH_KEYS"
    return 0
}

import_private_key() {
    local src="$1"
    if [[ ! -f "$src" ]]; then
        log_error "File not found: $src"
        return 1
    fi

    local key_name
    key_name=$(basename "$src")
    local dest="$SSH_DIR/$key_name"

    if [[ ! "$key_name" =~ ^id_ ]]; then
        dest="$SSH_DIR/id_rsa_$key_name"
    fi

    if [[ -f "$dest" ]]; then
        log_warn "File $dest already exists. Overwrite? [y/N]"
        read -r confirm
        if [[ ! "$confirm" =~ ^[yY] ]]; then
            log_info "Skipped."
            return 0
        fi
    fi

    cp "$src" "$dest"
    chmod 600 "$dest"
    log_success "Private key imported to $dest"
    return 0
}

set_password_auth() {
    local value="$1"
    backup_sshd_config

    if grep -q '^PasswordAuthentication' "$SSHD_CONFIG"; then
        sudo sed -i "s/^PasswordAuthentication.*/PasswordAuthentication $value/" "$SSHD_CONFIG"
    else
        echo "PasswordAuthentication $value" | sudo tee -a "$SSHD_CONFIG" > /dev/null
    fi

    if grep -q '^ChallengeResponseAuthentication' "$SSHD_CONFIG"; then
        sudo sed -i "s/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication $value/" "$SSHD_CONFIG"
    else
        echo "ChallengeResponseAuthentication $value" | sudo tee -a "$SSHD_CONFIG" > /dev/null
    fi

    if grep -q '^UsePAM' "$SSHD_CONFIG"; then
        sudo sed -i "s/^UsePAM.*/UsePAM $value/" "$SSHD_CONFIG" 2>/dev/null || true
    fi

    restart_ssh

    if [[ "$value" == "no" ]]; then
        log_success "Password authentication disabled. Only key-based SSH allowed."
    else
        log_success "Password authentication enabled."
    fi
}

reset_password() {
    log_info "Enter new password for user $USER"
    if passwd; then
        log_success "Password updated successfully."
    else
        log_error "Failed to update password."
        return 1
    fi
}

list_keys() {
    if [[ ! -f "$AUTH_KEYS" ]] || [[ ! -s "$AUTH_KEYS" ]]; then
        log_info "No public keys in authorized_keys."
        return 1
    fi
    echo -e "${CYAN}Public keys in $AUTH_KEYS:${NC}"
    local i=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local comment
        comment=$(echo "$line" | awk '{print $NF}')
        local ktype
        ktype=$(echo "$line" | awk '{print $1}')
        printf "  %d) %s %s\n" "$i" "$ktype" "$comment"
        : $((i++))
    done < "$AUTH_KEYS"
    return 0
}

remove_key_by_index() {
    local index="$1"
    if [[ ! -f "$AUTH_KEYS" ]] || [[ ! -s "$AUTH_KEYS" ]]; then
        log_error "No keys to remove."
        return 1
    fi

    local tmp
    tmp=$(mktemp)
    local count=0
    local removed=0
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            echo "" >> "$tmp"
            continue
        fi
        : $((count++))
        if [[ "$count" -eq "$index" ]]; then
            removed=1
            continue
        fi
        echo "$line" >> "$tmp"
    done < "$AUTH_KEYS"

    if [[ "$removed" -eq 0 ]]; then
        log_error "Invalid key index: $index"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$AUTH_KEYS"
    fix_permissions
    log_success "Key #$index removed from authorized_keys"
    return 0
}

interactive_add_key() {
    echo -e "${CYAN}Add SSH Public Key${NC}"
    echo "1) Paste key content"
    echo "2) Provide file path"
    read -r -p "Choose [1/2]: " choice
    case "$choice" in
        1)
            read -r -p "Paste your public key: " key
            add_public_key "$key"
            ;;
        2)
            read -r -p "Enter file path: " path
            path="${path/#\~/$HOME}"
            add_public_key "$path"
            ;;
        *)
            log_error "Invalid choice."
            ;;
    esac
}

interactive_import_key() {
    echo -e "${CYAN}Import SSH Private Key${NC}"
    read -r -p "Enter path to private key file: " path
    path="${path/#\~/$HOME}"
    import_private_key "$path"
}

interactive_reset_password() {
    echo -e "${CYAN}Reset Login Password${NC}"
    reset_password
}

interactive_disable_password() {
    echo -e "${YELLOW}This will disable password SSH authentication.${NC}"
    echo -e "${YELLOW}Ensure you have a key added and can connect before proceeding!${NC}"
    read -r -p "Are you sure? [y/N]: " confirm
    if [[ "$confirm" =~ ^[yY] ]]; then
        require_sudo
        set_password_auth "no"
    else
        log_info "Cancelled."
    fi
}

interactive_enable_password() {
    require_sudo
    set_password_auth "yes"
}

interactive_remove_key() {
    if ! list_keys; then
        log_warn "Cannot proceed with removal."
        return
    fi

    local total
    total=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|ssh-dss)' "$AUTH_KEYS" 2>/dev/null || echo 0)
    if [[ "$total" -eq 0 ]]; then
        return
    fi

    read -r -p "Enter the number of the key to remove: " num
    if [[ "$num" =~ ^[0-9]+$ ]]; then
        remove_key_by_index "$num"
    else
        log_error "Invalid number."
    fi
}

show_menu() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         SSH Manager Tool             ║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  1) Add SSH Public Key              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  2) Import SSH Private Key          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  3) Disable Password Authentication ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  4) Enable & Reset Login Password   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  5) Add Key + Disable Password      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  6) Remove Key + Enable Password    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  7) Remove Key + Enable PW + Reset  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  8) Exit                            ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo ""
}

usage() {
    cat <<EOF
Usage: ssh-manager.sh [OPTION]

Options:
  --add-key <path>          Add SSH public key from file or string
  --import-key <path>       Import SSH private key
  --disable-password        Disable SSH password authentication
  --enable-password         Enable SSH password authentication
  --reset-password          Reset login password
  --remove-key <index>      Remove public key by index number
  --list-keys               List all public keys
  --help                    Show this help message

Without options, launches interactive menu.
EOF
    exit 0
}

main() {
    case "${1:-}" in
        --add-key)
            [[ -z "${2:-}" ]] && { log_error "Missing argument for --add-key"; exit 1; }
            add_public_key "$2"
            ;;
        --import-key)
            [[ -z "${2:-}" ]] && { log_error "Missing argument for --import-key"; exit 1; }
            import_private_key "$2"
            ;;
        --disable-password)
            require_sudo
            set_password_auth "no"
            ;;
        --enable-password)
            require_sudo
            set_password_auth "yes"
            ;;
        --reset-password)
            reset_password
            ;;
        --remove-key)
            [[ -z "${2:-}" ]] && { log_error "Missing argument for --remove-key"; exit 1; }
            remove_key_by_index "$2"
            ;;
        --list-keys)
            list_keys
            ;;
        --help)
            usage
            ;;
        "")
            while true; do
                show_menu
                read -r -p "Enter your choice [1-8]: " choice
                echo ""
                case "$choice" in
                    1) interactive_add_key ;;
                    2) interactive_import_key ;;
                    3) interactive_disable_password ;;
                    4) interactive_enable_password; interactive_reset_password ;;
                    5) interactive_add_key; interactive_disable_password ;;
                    6) interactive_remove_key; interactive_enable_password ;;
                    7) interactive_remove_key; interactive_enable_password; interactive_reset_password ;;
                    8) log_info "Goodbye!"; exit 0 ;;
                    *) log_error "Invalid choice. Please enter 1-8." ;;
                esac
            done
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
}

main "$@"
