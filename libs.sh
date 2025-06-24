#!/bin/bash

FN_UTILS=(jq curl dig nc dialog fzf unzip netstat ifconfig lsof ss socat nmap iperf3 yq shyaml)

FN_LOG() {
  local level="$1"; shift
  local ts="$(date '+%Y-%m-%d %H:%M:%S')"

  case "$level" in
    info)  echo -e "[${ts}] \033[1;32mINFO \033[0m$*" ;;
    warn)  echo -e "[${ts}] \033[1;33mWARN \033[0m$*" ;;
    error) echo -e "[${ts}] \033[1;31mERROR\033[0m$*" ;;
    *)   echo -e "[${ts}] \033[1;34mLOG  \033[0m$*" ;;
  esac
}

FN_CMSG() {
  local style="$1"
  local message="$2"
  local fg bg raw_attr ansi
  local attr=()

  IFS=':' read -r fg bg raw_attr <<< "$style"
  fg="${fg:-7}" 
  bg="${bg:-0}" 
  raw_attr="${raw_attr^^}" 

  [[ "$raw_attr" == *"B"* ]]  && attr+=("1")
  [[ "$raw_attr" == *"U"* ]]  && attr+=("4")
  [[ "$raw_attr" == *"BL"* ]] && attr+=("5")
  [[ "$raw_attr" == *"R"* ]]  && attr+=("7")

  ansi="\033[$(IFS=';'; echo "${attr[*]}");3${fg};4${bg}m"
  echo -e "${ansi}${message}\033[0m"
}

FN_TEST() {
  local type="$1"
  local value="$2"

  case "$type" in
    email)    [[ "$value" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] ;;
    domain)   [[ "$value" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] ;;
    ip)       [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && awk -F. '{for(i=1;i<=4;i++) if($i<0||$i>255) exit 1}' <<< "$value" ;;
    port)     [[ "$value" =~ ^[0-9]{1,5}$ ]] && (( value >= 1 && value <= 65535 )) ;;
    number)   [[ "$value" =~ ^-?[0-9]+$ ]] ;;
    float)    [[ "$value" =~ ^-?[0-9]+([.][0-9]+)?$ ]] ;;
    hex)      [[ "$value" =~ ^0x[0-9a-fA-F]+$ ]] ;;
    base64)   [[ "$value" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] ;;
    uuid)     [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ;;
    path)     [[ "$value" =~ ^/[^[:cntrl:]]*$ ]] ;;
    username) [[ "$value" =~ ^[a-zA-Z0-9_-]{3,32}$ ]] ;;
    password) [[ ${#value} -ge 8 ]] && [[ "$value" =~ [A-Z] ]] && [[ "$value" =~ [a-z] ]] && [[ "$value" =~ [0-9] ]] && [[ "$value" =~ [^a-zA-Z0-9] ]] ;;
    url)      [[ "$value" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]] ;;
    *)     FN_LOG error "Unknown test type: $type"; return 1 ;;
  esac
}

FN_YN() {
  local prompt="$1"
  local ans
  while true; do
    read -rp "$prompt [y/n]: " ans
    case "${ans,,}" in
      y) return 0 ;;
      n) return 1 ;;
      *) FN_LOG warn "Please type y or n." ;;
    esac
  done
}

FN_DIR() {
  local path="$1"
  if [[ -d "$path" ]]; then
    return 0
  else
    FN_LOG error "Directory not found: $path"
    return 1
  fi
}

FN_FILE() {
  local path="$1"
  if [[ -f "$path" ]]; then
    return 0
  else
    FN_LOG error "File not found: $path"
    return 1
  fi
}

FN_PROMPT() {
  local var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local validate_type="${4:-}"  
  local required="${5:-false}"

  local input

  while true; do
    if [[ -n "$default" ]]; then
      FN_CMSG "6:0:B" "$prompt [$default]: "
    else
      FN_CMSG "6:0:B" "$prompt: "
    fi

    read -r input

    if [[ -z "$input" ]]; then
      if [[ "$required" == "true" && -z "$default" ]]; then
        FN_LOG warn "This field is required."
        continue
      elif [[ -n "$default" ]]; then
        input="$default"
      fi
    fi

    if [[ -n "$validate_type" ]]; then
      if ! FN_TEST "$validate_type" "$input"; then
        FN_LOG warn "Invalid format for $validate_type"
        continue
      fi
    fi

    break
  done

  printf -v "$var_name" '%s' "$input"
}

FN_FREAD() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    FN_LOG error "File not found: $file"
    return 1
  elif [[ ! -s "$file" ]]; then
    FN_LOG warn "File is empty: $file"
    return 2
  fi

  cat "$file"
}

FN_FREAD_LINES() {
  local file="$1"
  local -n _result="$2" 

  if [[ ! -f "$file" ]]; then
    FN_LOG error "File not found: $file"
    return 1
  elif [[ ! -s "$file" ]]; then
    FN_LOG warn "File is empty: $file"
    return 2
  fi

`mapfile -t _result < "$file"
}

