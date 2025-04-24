#!/bin/bash
# ===========================================================
# LLM Launcher - Utility to configure and start OpenWebUI with various LLM backends
# 
# Supported backend options:
# - Local Ollama
# - Remote LM Studio server
# - Ollama in Docker container with Intel GPU acceleration
# - LocalAI with Intel SYCL acceleration
# ===========================================================

# Enable better error detection and handling
set -o pipefail

# List of started containers for cleanup
STARTED_CONTAINERS=""
DEBUG=${DEBUG:-false}
VERBOSE=${VERBOSE:-false}

# Base paths for configuration and data
LLM_BASE_DIR="${HOME}/llm"
CONFIG_FILE="${LLM_BASE_DIR}/llm-launcher.conf"

# Terminal color definitions for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Standardized output functions
error() { echo -e "${RED}ERROR: $1${NC}" >&2; echo; }
success() { echo -e "${GREEN}SUCCESS: $1${NC}"; echo; }
warning() { echo -e "${YELLOW}WARNING: $1${NC}"; echo; }
info() { echo -e "${BLUE}INFO: $1${NC}"; }
debug() { [[ "$DEBUG" == "true" ]] && echo -e "${CYAN}DEBUG: $1${NC}"; }

# Improved signal handling and cleanup
cleanup() {
  info "Cleaning up..."
  
  # Stop containers in reverse order of starting
  if [[ -n "$STARTED_CONTAINERS" ]]; then
    local containers=(${STARTED_CONTAINERS})
    for ((i=${#containers[@]}-1; i>=0; i--)); do
      local container="${containers[$i]}"
      info "Stopping container $container..."
      docker stop "$container" &>/dev/null
    done
  fi
  
  # Additional cleanup tasks can be added here
  info "Cleanup completed"
  
  return 0
}

# Setup trap for common signals
trap 'echo -e "\n${YELLOW}Received interrupt signal. Cleaning up...${NC}"; cleanup; exit 1;' SIGINT SIGTERM SIGHUP

# Prompt user with timeout to prevent script hanging indefinitely
prompt_with_timeout() {
  local prompt="$1"
  local timeout="${2:-30}"  # Default timeout in seconds
  local default="${3:-n}"   # Default answer if timeout occurs
  
  echo -e -n "$prompt "
  read -t "$timeout" -r response || true
  
  if [ -z "$response" ]; then
    echo -e "\nUsing default: $default"
    response="$default"
  fi
  
  [[ $response =~ ^[Yy]$ ]]
  return $?
}

# Check if script is run as root
check_root() {
  if [[ $EUID -eq 0 ]]; then
    warning "Running this script as root is not recommended"
    warning "Docker should be configured to run without sudo"
    if ! prompt_with_timeout "${YELLOW}Continue anyway? (y/n):${NC}" 10 "n"; then
      exit 1
    fi
  fi
}

# Check Docker permissions
check_docker_permissions() {
  debug "Checking Docker permissions..."
  
  # First check if docker command exists
  if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Please install it before continuing."
    return 1
  fi
  
  # Check if user can run docker without sudo
  if ! docker info &>/dev/null; then
    warning "Cannot run Docker commands. Checking if sudo access is available..."
    
    # Try with sudo if available
    if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
      if sudo docker info &>/dev/null; then
        warning "Docker requires sudo privileges. It's recommended to add your user to the docker group:"
        warning "    sudo usermod -aG docker $USER && newgrp docker"
        if ! prompt_with_timeout "${YELLOW}Continue using sudo for Docker commands? (y/n):${NC}" 10 "n"; then
          return 1
        fi
        info "Will use sudo for Docker commands"
        # Create function to prepend sudo to docker commands
        function docker() {
          sudo docker "$@"
        }
        export -f docker
      else
        error "Cannot run Docker even with sudo. Please check your Docker installation."
        return 1
      fi
    else
      error "Cannot run Docker commands and sudo is not available."
      error "Please ensure Docker is properly installed and your user has proper permissions."
      return 1
    fi
  fi
  
  return 0
}

# Hardware detection and automatic resource allocation
detect_hardware() {
  info "Detecting hardware capabilities..."
  
  # Detect total memory
  local TOTAL_MEM=$(free -g | awk '/^Mem:/{print $2}')
  if [[ $TOTAL_MEM -lt 8 ]]; then
    warning "Low memory detected: ${TOTAL_MEM}G. This may impact performance."
    RECOMMENDED_MEM="${TOTAL_MEM}G"
    RECOMMENDED_SHM="$((TOTAL_MEM / 2))g"
  else
    RECOMMENDED_MEM="$((TOTAL_MEM * 80 / 100))G"  # 80% of available memory
    RECOMMENDED_SHM="$((TOTAL_MEM * 50 / 100))g"  # 50% of available memory
  fi
  
  # Detect CPU cores
  local CPU_CORES=$(nproc --all)
  RECOMMENDED_THREADS=$((CPU_CORES > 4 ? CPU_CORES - 2 : CPU_CORES))
  
  # Detect GPU type
  if command -v lspci &>/dev/null; then
    local GPU_INFO=$(lspci | grep -i 'vga\|3d\|display')
    if [[ $GPU_INFO =~ [Nn][Vv][Ii][Dd][Ii][Aa] ]]; then
      GPU_TYPE="NVIDIA"
      GPU_PARAMS="--gpus all"
      debug "NVIDIA GPU detected"
    elif [[ $GPU_INFO =~ [Aa][Mm][Dd] ]]; then
      GPU_TYPE="AMD"
      GPU_PARAMS="--device=/dev/dri"
      debug "AMD GPU detected"
    elif [[ $GPU_INFO =~ [Ii][Nn][Tt][Ee][Ll] ]]; then
      GPU_TYPE="INTEL"
      GPU_PARAMS="--device=/dev/dri"
      debug "Intel GPU detected"
    else
      GPU_TYPE="NONE"
      GPU_PARAMS=""
      debug "No supported GPU detected"
    fi
  else
    GPU_TYPE="UNKNOWN"
    GPU_PARAMS="--device=/dev/dri"
    debug "Cannot detect GPU (lspci not available)"
  fi
  
  # Print hardware summary
  info "System resources detected:"
  info "  - Memory: ${TOTAL_MEM}G (Recommended: ${RECOMMENDED_MEM})"
  info "  - CPU Cores: ${CPU_CORES} (Recommended threads: ${RECOMMENDED_THREADS})"
  info "  - GPU Type: ${GPU_TYPE}"
  
  # Update config values if they exist
  if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
    # Only suggest changes if values are significantly different
    if [[ ${MEMORY_LIMIT%[A-Za-z]} -lt ${RECOMMENDED_MEM%[A-Za-z]} ]]; then
      if prompt_with_timeout "${YELLOW}Current memory limit (${MEMORY_LIMIT}) is less than recommended (${RECOMMENDED_MEM}). Update? (y/n):${NC}" 10 "n"; then
        sed -i "s/^MEMORY_LIMIT=.*/MEMORY_LIMIT=\"${RECOMMENDED_MEM}\"/" "${CONFIG_FILE}"
        MEMORY_LIMIT="${RECOMMENDED_MEM}"
      fi
    fi
    if [[ ${SHM_SIZE%[A-Za-z]} -lt ${RECOMMENDED_SHM%[A-Za-z]} ]]; then
      if prompt_with_timeout "${YELLOW}Current shared memory (${SHM_SIZE}) is less than recommended (${RECOMMENDED_SHM}). Update? (y/n):${NC}" 10 "n"; then
        sed -i "s/^SHM_SIZE=.*/SHM_SIZE=\"${RECOMMENDED_SHM}\"/" "${CONFIG_FILE}"
        SHM_SIZE="${RECOMMENDED_SHM}"
      fi
    fi
    # Update extra flags for LocalAI
    if [[ "${LOCALAI_EXTRA_FLAGS}" != *"--threads ${RECOMMENDED_THREADS}"* ]]; then
      if prompt_with_timeout "${YELLOW}Update LocalAI thread count to ${RECOMMENDED_THREADS}? (y/n):${NC}" 10 "n"; then
        sed -i "s/^LOCALAI_EXTRA_FLAGS=.*/LOCALAI_EXTRA_FLAGS=\"--threads ${RECOMMENDED_THREADS}\"/" "${CONFIG_FILE}"
        LOCALAI_EXTRA_FLAGS="--threads ${RECOMMENDED_THREADS}"
      fi
    fi
  fi
}

# Check service system (systemd or other)
get_service_manager() {
  if command -v systemctl &>/dev/null; then
    echo "systemd"
  elif command -v service &>/dev/null; then
    echo "sysvinit"
  else
    echo "none"
  fi
}

# Display usage instructions and available options
show_help() {
  echo -e "${CYAN}========== LLM Launcher Help ==========${NC}"
  echo "This script launches OpenWebUI with different LLM backends."
  echo
  echo "Options:"
  echo "  --help, -h                Show this help message"
  echo "  --setup-dirs              Create the necessary standard directories"
  echo "  --create-config           Create or reset the default configuration file"
  echo "  --edit-config             Edit the configuration file"
  echo "  --check-network           Check Docker network status and container connectivity"
  echo "  --stop                    Stop running containers and services started by this script"
  echo "  --non-interactive         Run with default options (must specify backend with --backend)"
  echo "  --backend=TYPE            Specify backend type: ollama, lmstudio, ollama-container, localai"
  echo "  --verbose                 Enable verbose output"
  echo "  --debug                   Enable debug output"
  echo "  --detect-hardware         Detect hardware and suggest settings"
  echo
  echo "Standard usage:"
  echo "  ./llm-launcher.sh          Launch normally using existing configurations"
  echo "  ./llm-launcher.sh --stop   Stop running services and containers"
  echo
  echo "Recommended first run:"
  echo "  ./llm-launcher.sh --setup-dirs --create-config"
  echo "  ./llm-launcher.sh --edit-config"
  echo "  ./llm-launcher.sh"
  echo -e "${CYAN}=====================================${NC}"
}

# Create the standard directory structure for model and data storage
setup_directories() {
  info "Checking and creating necessary directories..."
  
  # Standard directory structure for all supported backends
  local required_dirs=(
    "${LLM_BASE_DIR}"                    # Base directory
    "${LLM_BASE_DIR}/models"             # All models
    "${LLM_BASE_DIR}/models/ollama"      # Ollama models
    "${LLM_BASE_DIR}/models/localai"     # LocalAI models
    "${LLM_BASE_DIR}/data"               # All application data
    "${LLM_BASE_DIR}/data/open-webui"    # OpenWebUI persistent data
    "${LLM_BASE_DIR}/logs"               # Log files
  )
  
  local created_count=0
  
  for dir in "${required_dirs[@]}"; do
    if [ ! -d "$dir" ]; then
      mkdir -p "$dir"
      ((created_count++))
      info "Created new directory: $dir"
    fi
  done
  
  if [ $created_count -eq 0 ]; then
    success "All required directories were already present."
  else
    success "Directory structure updated. Created $created_count new directories."
  fi
}

# Function to create the default configuration file
create_default_config() {
  info "Checking configuration file status..."
  
  # Check if configuration file already exists
  if [ -f "${CONFIG_FILE}" ]; then
    if prompt_with_timeout "${YELLOW}Configuration file exists. Backup and create new one? (y/n):${NC}" 10; then
      # Create a backup with timestamp
      local BACKUP_FILE="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
      cp "${CONFIG_FILE}" "${BACKUP_FILE}"
      success "Existing configuration backed up to: ${BACKUP_FILE}"
    else
      info "Keeping existing configuration file."
      return 0
    fi
  fi
  
  info "Creating the default configuration file..."
  
  # Detect hardware for better defaults
  local DETECTED_MEM=$(free -g | awk '/^Mem:/{print $2}')
  local MEM_LIMIT="$((DETECTED_MEM * 80 / 100))G"  # 80% of available memory
  local SHARE_MEM="$((DETECTED_MEM / 2))g"  # 50% of available memory
  local CPU_CORES=$(nproc --all)
  local THREADS=$((CPU_CORES > 4 ? CPU_CORES - 2 : CPU_CORES))
  
  cat > "${CONFIG_FILE}" << EOF
# Configuration for llm-launcher.sh
# Modify these parameters according to your needs

# General settings
DOCKER_NETWORK="ollama-network"

# OpenWebUI
OPEN_WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
OPEN_WEBUI_NAME="open-webui"
OPEN_WEBUI_PORT="3000"

# Ollama in container
OLLAMA_CONTAINER_IMAGE="intelanalytics/ipex-llm-inference-cpp-xpu:latest"
OLLAMA_CONTAINER_NAME="ollama-container"
OLLAMA_CONTAINER_PORT="11434"

# LM Studio remote
LM_STUDIO_HOST="192.168.1.154"
LM_STUDIO_PORT="1234"

# LocalAI with Intel acceleration
LOCALAI_IMAGE="localai/localai:v2.27.0-sycl-f16-ffmpeg"
LOCALAI_NAME="localai-container"
LOCALAI_PORT="8080"
LOCALAI_MODEL="gemma-3-4b-it-qat"
LOCALAI_EXTRA_FLAGS="--threads ${THREADS}"

# Memory requirements (detected from system)
MEMORY_LIMIT="${MEM_LIMIT}"
SHM_SIZE="${SHARE_MEM}"

# Network diagnostics
NETWORK_DIAGNOSTIC_TIMEOUT="2" # seconds for timeout in connectivity tests
EOF

  success "Configuration file created at: ${CONFIG_FILE}"
}

# Function to edit the configuration file
edit_config() {
  # Check if the configuration file exists
  if [ ! -f "${CONFIG_FILE}" ]; then
    warning "Configuration file not found. Creating it now."
    create_default_config
  fi
  
  # Determine which editor to use
  if [ -n "$EDITOR" ]; then
    $EDITOR "${CONFIG_FILE}"
  elif command -v nano &> /dev/null; then
    nano "${CONFIG_FILE}"
  elif command -v vim &> /dev/null; then
    vim "${CONFIG_FILE}"
  elif command -v vi &> /dev/null; then
    vi "${CONFIG_FILE}"
  else
    error "No text editor found. Install nano, vim or set the \$EDITOR variable."
    return 1
  fi
  
  success "Configuration modified."
}

# Function to check prerequisites
check_prerequisites() {
  info "Checking prerequisites..."
  
  # Verify docker permissions 
  if ! check_docker_permissions; then
    return 1
  fi
  
  # Check basic directories
  if [ ! -d "${LLM_BASE_DIR}" ]; then
    if prompt_with_timeout "${YELLOW}Base directory ${LLM_BASE_DIR} not found. Create standard directories? (y/n)${NC}" 10; then
      setup_directories
    else
      error "Base directories not found. Run the command with --setup-dirs before continuing."
      return 1
    fi
  fi
  
  # Check configuration file
  if [ ! -f "${CONFIG_FILE}" ]; then
    if prompt_with_timeout "${YELLOW}Configuration file not found. Create it now? (y/n)${NC}" 10; then
      create_default_config
      if prompt_with_timeout "${YELLOW}Edit the configuration file before continuing? (y/n)${NC}" 10; then
        edit_config
      fi
    else
      error "Configuration file not found. Run the command with --create-config before continuing."
      return 1
    fi
  fi
  
  # Load configurations
  source "${CONFIG_FILE}"
  
  success "Prerequisites verified"
  return 0
}

# Generic connectivity check function
check_endpoint_connectivity() {
  local endpoint="$1"
  local friendly_name="$2"
  local timeout="${3:-3}"
  local continue_on_failure="${4:-false}"
  
  info "Checking connection to $friendly_name..."
  
  if ! curl -s --connect-timeout $timeout "$endpoint" > /dev/null; then
    warning "Cannot connect to $friendly_name at $endpoint"
    warning "Make sure it is running and accessible."
    
    if [[ "$continue_on_failure" == "false" ]]; then
      if ! prompt_with_timeout "${YELLOW}Continue anyway? (y/n):${NC}" 10; then
        return 1
      fi
    fi
    return 1
  else
    success "Connection to $friendly_name verified"
    return 0
  fi
}

# Generic function for container readiness
wait_for_container_endpoint() {
  local container_name="$1"
  local endpoint="$2"
  local friendly_name="$3"
  local max_wait="${4:-30}"
  
  info "Waiting for $friendly_name to start in the container..."
  local api_ready=false
  for ((i=1; i<=$max_wait; i++)); do
    if docker exec $container_name curl -s --connect-timeout 1 $endpoint > /dev/null; then
      api_ready=true
      success "$friendly_name is ready after $i seconds"
      break
    fi
    sleep 1
  done
  
  if ! $api_ready; then
    warning "$friendly_name is not responding after $max_wait seconds"
    warning "Continuing anyway, but there might be issues"
    return 1
  fi
  
  return 0
}

# Wait for service to start
wait_for_endpoint_ready() {
  local url="$1"
  local friendly_name="$2"
  local max_wait="${3:-30}"
  
  info "Waiting for $friendly_name to start..."
  local api_ready=false
  for ((i=1; i<=$max_wait; i++)); do
    if curl -s --connect-timeout 1 "$url" > /dev/null; then
      api_ready=true
      success "$friendly_name is ready after $i seconds"
      break
    fi
    sleep 1
  done
  
  if ! $api_ready; then
    warning "$friendly_name is not responding after $max_wait seconds"
    return 1
  fi
  
  return 0
}

# Configure backend parameters based on type
configure_backend_params() {
  local backend_type="$1"
  
  # Reset parameters
  WEBUI_ENV_PARAMS=()
  EXTRA_PARAMS=""
  
  case "$backend_type" in
    "ollama")
      OLLAMA_HOST_VAR="host.docker.internal"
      OLLAMA_URL_VAR="http://host.docker.internal:11434"
      EXTRA_PARAMS="--add-host=host.docker.internal:host-gateway"
      WEBUI_ENV_PARAMS=(
        "-e OLLAMA_BASE_URL=$OLLAMA_URL_VAR"
        "-e OLLAMA_API_HOST=$OLLAMA_HOST_VAR"
      )
      BACKEND_URL="http://localhost:11434"
      ;;
    
    "lmstudio")
      OPENAI_API_KEY="lm-studio"
      OPENAI_API_BASE_URL="http://$LM_STUDIO_HOST:$LM_STUDIO_PORT/v1"
      WEBUI_ENV_PARAMS=(
        "-e OPENAI_API_KEY=$OPENAI_API_KEY"
        "-e OPENAI_API_BASE_URL=$OPENAI_API_BASE_URL"
      )
      BACKEND_URL="http://$LM_STUDIO_HOST:$LM_STUDIO_PORT/v1/models"
      ;;
    
    "ollama-container")
      OLLAMA_HOST_VAR=$OLLAMA_CONTAINER_NAME
      OLLAMA_URL_VAR="http://$OLLAMA_CONTAINER_NAME:11434"
      WEBUI_ENV_PARAMS=(
        "-e OLLAMA_BASE_URL=$OLLAMA_URL_VAR"
        "-e OLLAMA_API_HOST=$OLLAMA_HOST_VAR"
      )
      BACKEND_URL="$OLLAMA_URL_VAR/api/version"
      ;;
    
    "localai")
      OPENAI_API_KEY="localai"
      OPENAI_API_BASE_URL="http://$LOCALAI_NAME:8080/v1"
      WEBUI_ENV_PARAMS=(
        "-e OPENAI_API_KEY=$OPENAI_API_KEY"
        "-e OPENAI_API_BASE_URL=$OPENAI_API_BASE_URL"
      )
      BACKEND_URL="http://localhost:${LOCALAI_PORT}/v1/models"
      ;;
  esac
  
  BACKEND_TYPE="$backend_type"
  return 0
}

# Generalized service management
manage_service() {
  local service_name="$1"
  local action="$2"  # start/stop/status
  
  local service_manager=$(get_service_manager)
  
  case "$service_manager" in
    "systemd")
      if systemctl list-unit-files | grep -q $service_name; then
        sudo systemctl $action $service_name
        return $?
      fi
      ;;
    "sysvinit")
      if service --status-all 2>&1 | grep -q $service_name; then
        sudo service $service_name $action
        return $?
      fi
      ;;
  esac
  
  # Fallback for manual service management
  if [[ "$action" == "start" ]]; then
    mkdir -p ${LLM_BASE_DIR}/logs
    nohup $service_name serve > ${LLM_BASE_DIR}/logs/$service_name.log 2>&1 &
    return $?
  elif [[ "$action" == "stop" ]]; then
    pkill -f "$service_name serve"
    return $?
  fi
  
  return 1
}

# Improved container start function to reduce code duplication
start_container() {
  local name="$1"
  local image="$2"
  local port_mapping="$3"
  local cmd="$4"
  shift 4
  
  info "Starting container $name..."
  debug "Image: $image"
  debug "Port mapping: $port_mapping"
  debug "Extra params: $*"
  
  # Build docker run command explicitly to avoid space issues
  local docker_cmd="docker run -d ${port_mapping} --name=${name} --network=${DOCKER_NETWORK}"
  
  # Add all additional parameters without any space issues
  for param in "$@"; do
    docker_cmd="${docker_cmd} ${param}"
  done
  
  # Add image and command
  docker_cmd="${docker_cmd} ${image}"
  if [ -n "$cmd" ]; then
    docker_cmd="${docker_cmd} ${cmd}"
  fi
  
  debug "Full docker command: $docker_cmd"
  
  if eval ${docker_cmd}; then
    STARTED_CONTAINERS="$STARTED_CONTAINERS $name"
    success "Container '$name' started successfully"
    return 0
  else
    error "Failed to start container '$name'"
    return 1
  fi
}

# Pull latest Docker image or use existing local image if download fails
update_docker_image() {
  local image_name="$1"
  local friendly_name="$2"
  
  info "Checking updates for $friendly_name ($image_name)..."
  
  # Check if we already have a local copy
  local image_exists_locally=false
  if docker image inspect "$image_name" &>/dev/null; then
    image_exists_locally=true
    info "$friendly_name image found locally"
  else
    info "$friendly_name image not found locally"
  fi
  
  # Try to download latest version (no timeout)
  if docker pull "$image_name"; then
    success "$friendly_name image updated/downloaded successfully"
    return 0
  fi
  
  # Handle download failure
  if $image_exists_locally; then
    # We have a local copy, ask if user wants to use it
    if prompt_with_timeout "${YELLOW}Failed to download $friendly_name. Use local version? (y/n):${NC}" 10 "y"; then
      info "Using the local version of $friendly_name"
      return 0
    else
      error "Operation cancelled for $friendly_name"
      return 1
    fi
  else
    error "The $friendly_name image is not available either online or locally"
    return 1
  fi
}

# Function to create the docker network
create_docker_network() {
  info "Checking Docker network '$DOCKER_NETWORK'..."
  
  if ! docker network inspect $DOCKER_NETWORK &>/dev/null; then
    info "Creating Docker network '$DOCKER_NETWORK'..."
    if docker network create $DOCKER_NETWORK; then
      success "Docker network '$DOCKER_NETWORK' created"
    else
      error "Unable to create Docker network '$DOCKER_NETWORK'"
      return 1
    fi
  else
    info "Docker network '$DOCKER_NETWORK' already exists"
  fi
  
  return 0
}

# Function to check and remove existing containers
remove_container_if_exists() {
  local container_name="$1"
  
  if [ "$(docker ps -aq -f name=^/${container_name}$)" ]; then
    info "Removing existing '$container_name' container..."
    if docker rm -f $container_name &>/dev/null; then
      success "Container '$container_name' removed"
    else
      error "Unable to remove container '$container_name'"
      return 1
    fi
  fi
  
  return 0
}

# Diagnostic tool to check Docker network configuration and container connectivity
check_network_status() {
  info "Checking Docker network status..."

  # Verify network exists
  if ! docker network inspect $DOCKER_NETWORK &>/dev/null; then
    error "Docker network '$DOCKER_NETWORK' does not exist"
    info "Run the script normally to create the network first"
    return 1
  fi

  # Show network configuration
  echo -e "${CYAN}Network details:${NC}"
  docker network inspect $DOCKER_NETWORK | grep -A 2 "Name\|Driver\|Subnet"
  echo

  # Get list of containers in this network
  echo -e "${CYAN}Containers in network $DOCKER_NETWORK:${NC}"
  local CONTAINERS=$(docker network inspect $DOCKER_NETWORK | grep -o '"Name": "[^"]*' | grep -v "Name.*:" | cut -d'"' -f4)
  
  if [ -z "$CONTAINERS" ]; then
    echo "No containers found in network $DOCKER_NETWORK"
    return 0
  fi

  # Show container IP addresses
  echo "$CONTAINERS" | while read container; do
    local CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $container 2>/dev/null || echo "Not running")
    echo -e "$container: ${BLUE}$CONTAINER_IP${NC}"
  done
  echo

  # Test container-to-container connectivity
  echo -e "${CYAN}Testing basic network connectivity:${NC}"
  local container_array=()
  while read -r line; do
    container_array+=("$line")
  done <<< "$CONTAINERS"

  # Test each pair of containers
  for ((i=0; i<${#container_array[@]}; i++)); do
    for ((j=i+1; j<${#container_array[@]}; j++)); do
      local container1=${container_array[$i]}
      local container2=${container_array[$j]}
      
      # Skip if containers aren't running
      if ! docker ps -q -f "name=$container1" &>/dev/null || ! docker ps -q -f "name=$container2" &>/dev/null; then
        echo -e "$container1 <-> $container2: ${YELLOW}One or both containers not running${NC}"
        continue
      fi
      
      # Test ping with timeout
      if docker exec $container1 timeout $NETWORK_DIAGNOSTIC_TIMEOUT ping -c 1 $container2 &>/dev/null; then
        echo -e "$container1 -> $container2: ${GREEN}Network connectivity OK${NC}"
      else
        echo -e "$container1 -> $container2: ${YELLOW}Network connectivity issue${NC}"
      fi
    done
  done
  
  return 0
}

# Function to configure and launch local Ollama (option 1)
setup_local_ollama() {
  info "Configuring Ollama on the local host..."
  
  # Verify if Ollama is running on the host
  if ! curl -s --connect-timeout 2 http://localhost:11434/api/version > /dev/null; then
    warning "Cannot connect to Ollama on the local host."
    
    # Check if Ollama is installed
    if ! command -v ollama &> /dev/null; then
      warning "Ollama does not appear to be installed on the system."
      warning "Install Ollama from https://ollama.ai/ before continuing."
      
      if ! prompt_with_timeout "${YELLOW}Continue without Ollama? (y/n):${NC}" 10; then
        return 1
      fi
    else
      if prompt_with_timeout "${YELLOW}Try starting Ollama service? (y/n):${NC}" 10; then
        info "Attempting to start Ollama service..."
        
        # Use the generic service management function
        if manage_service "ollama" "start"; then
          info "Ollama service started"
        else
          info "Started Ollama manually"
        fi
        
        # Use the generic wait for endpoint function
        if ! wait_for_endpoint_ready "http://localhost:11434/api/version" "Ollama"; then
          warning "Unable to start Ollama. Verify the installation."
          if ! prompt_with_timeout "${YELLOW}Continue without active Ollama? (y/n):${NC}" 10; then
            return 1
          fi
        else
          success "Ollama started successfully!"
        fi
      elif ! prompt_with_timeout "${YELLOW}Continue without active Ollama? (y/n):${NC}" 10; then
        return 1
      fi
    fi
  else
    success "Connection to Ollama on host verified"
  fi
  
  # Use the generic backend configuration function
  configure_backend_params "ollama"
  
  return 0
}

# Function to configure remote LM Studio (option 2)
setup_lm_studio() {
  info "Configuring to use LM Studio on another PC ($LM_STUDIO_HOST:$LM_STUDIO_PORT)..."
  
  # Use the generic connectivity check
  check_endpoint_connectivity "http://$LM_STUDIO_HOST:$LM_STUDIO_PORT/v1/models" "LM Studio" 3
  
  # Use the generic backend configuration function
  configure_backend_params "lmstudio"
  
  return 0
}

# Function to configure and start Ollama in container (option 3)
setup_ollama_container() {
  info "Configuring Ollama in Docker container..."
  
  # Update the image and handle errors
  if ! update_docker_image "$OLLAMA_CONTAINER_IMAGE" "Ollama Container"; then
    return 1
  fi
  
  # Remove the Ollama container if it exists
  if ! remove_container_if_exists $OLLAMA_CONTAINER_NAME; then
    return 1
  fi
  
  # Start the Ollama container using the common function
  if ! start_container "$OLLAMA_CONTAINER_NAME" \
    "$OLLAMA_CONTAINER_IMAGE" \
    "-p $OLLAMA_CONTAINER_PORT:11434" \
    "bash -c 'ln -s /llm/ollama/ollama /usr/local/bin/ollama && cd /llm/scripts && source ipex-llm-init --gpu --device iGPU && bash start-ollama.sh && tail -f /dev/null'" \
    "$GPU_PARAMS" \
    "-v ${LLM_BASE_DIR}/models/ollama:/root/.ollama/models" \
    "-e OLLAMA_HOST=0.0.0.0" \
    "--memory=${MEMORY_LIMIT}" \
    "--shm-size=${SHM_SIZE}"; then
    return 1
  fi
  
  # Use the generic wait for container function
  wait_for_container_endpoint "$OLLAMA_CONTAINER_NAME" "http://localhost:11434/api/version" "Ollama API"
  
  # Use the generic backend configuration function
  configure_backend_params "ollama-container"
  
  success "Ollama container started successfully"
  return 0
}

# Function to configure and start LocalAI with Intel acceleration (option 4)
setup_localai() {
  info "Configuring LocalAI with Intel acceleration (SYCL)..."
  
  # Update the image and handle errors
  if ! update_docker_image "$LOCALAI_IMAGE" "LocalAI"; then
    return 1
  fi
  
  # Remove the LocalAI container if it exists
  if ! remove_container_if_exists $LOCALAI_NAME; then
    return 1
  fi
  
  # Create models directory
  mkdir -p "${LLM_BASE_DIR}/models/localai"
  
  # Start the LocalAI container using the common function
  if ! start_container "$LOCALAI_NAME" \
    "$LOCALAI_IMAGE" \
    "-p ${LOCALAI_PORT}:8080" \
    "$LOCALAI_MODEL $LOCALAI_EXTRA_FLAGS" \
    "$GPU_PARAMS" \
    "-v ${LLM_BASE_DIR}/models/localai:/build/models" \
    "-e DEBUG=true" \
    "-e MODELS_PATH=/build/models" \
    "-e THREADS=1" \
    "--shm-size=${SHM_SIZE}"; then
    return 1
  fi
  
  # Use the generic wait for endpoint function
  wait_for_endpoint_ready "http://localhost:${LOCALAI_PORT}/v1/models" "LocalAI API"
  
  # Use the generic backend configuration function
  configure_backend_params "localai"
  
  success "LocalAI container started successfully"
  return 0
}

# Launch the OpenWebUI container with appropriate backend configuration
start_open_webui() {
  info "Preparing OpenWebUI..."
  
  # Get latest image or verify local image is available
  if ! update_docker_image "$OPEN_WEBUI_IMAGE" "OpenWebUI"; then
    return 1
  fi
  
  # Remove existing container to avoid conflicts
  if ! remove_container_if_exists $OPEN_WEBUI_NAME; then
    return 1
  fi
  
  # Prepare container parameters
  local docker_args=(
    "-v ${LLM_BASE_DIR}/data/open-webui:/app/backend/data"
    "-e WEBUI_AUTH=false" # Disable authentication for all backends
  )
  
  # Configure backend-specific parameters
  case "$BACKEND_TYPE" in
    "ollama"|"ollama-container")
      # For Ollama backend, enable Ollama API and disable OpenAI
      docker_args+=("-e ENABLE_OLLAMA_API=true")
      docker_args+=("-e ENABLE_OPENAI_API=false")
      docker_args+=("-e ENABLE_DIRECT_CONNECTIONS=false")
      ;;
    "lmstudio"|"localai")
      # For OpenAI-compatible backends, disable Ollama API and enable OpenAI
      docker_args+=("-e ENABLE_OLLAMA_API=false")
      docker_args+=("-e ENABLE_OPENAI_API=true")
      docker_args+=("-e ENABLE_DIRECT_CONNECTIONS=true")
      ;;
  esac
  
  # Add all environment variables from backend setup
  for param in "${WEBUI_ENV_PARAMS[@]}"; do
    docker_args+=($param)
  done
  
  # Add host mapping or other extra parameters if needed
  if [ -n "$EXTRA_PARAMS" ]; then
    docker_args+=($EXTRA_PARAMS)
  fi
  
  # Start OpenWebUI container using the common function
  if ! start_container "$OPEN_WEBUI_NAME" \
    "$OPEN_WEBUI_IMAGE" \
    "-p ${OPEN_WEBUI_PORT}:8080" \
    "" \
    "${docker_args[@]}"; then
    return 1
  fi
  
  success "OpenWebUI started successfully"
  return 0
}

# Test connectivity between OpenWebUI and the selected LLM backend
verify_connectivity() {
  info "Verifying connectivity between OpenWebUI and the backend..."
  
  # Determine appropriate API endpoint to test based on backend type
  local test_url=""
  
  case "$BACKEND_TYPE" in
    "ollama")
      test_url="$OLLAMA_URL_VAR/api/version"
      ;;
    "ollama-container")
      test_url="$BACKEND_URL"
      ;;
    "lmstudio")
      test_url="$BACKEND_URL"
      ;;
    "localai")
      test_url="${OPENAI_API_BASE_URL}/models"
      ;;
  esac
  
  # Use docker exec to check from inside the OpenWebUI container
  if docker exec $OPEN_WEBUI_NAME curl -s --connect-timeout 5 "$test_url" > /dev/null; then
    success "OpenWebUI can connect to the $BACKEND_TYPE backend"
    return 0
  else
    warning "OpenWebUI cannot connect to the $BACKEND_TYPE backend"
    warning "Check network settings and ensure the backend is running"
    return 1
  fi
}

# Function to display access information
show_access_info() {
  echo
  echo "========================================================"
  echo -e "${GREEN}Configuration completed!${NC}"
  echo "========================================================"
  echo -e "OpenWebUI is accessible at: ${BLUE}http://localhost:${OPEN_WEBUI_PORT}${NC}"
  
  case "$BACKEND_TYPE" in
    "ollama")
      echo -e "Ollama API is accessible at: ${BLUE}http://localhost:11434${NC}"
      ;;
    "ollama-container")
      echo -e "Ollama in container is accessible at: ${BLUE}http://localhost:$OLLAMA_CONTAINER_PORT${NC}"
      echo -e "Ollama Container: ${BLUE}$OLLAMA_CONTAINER_NAME${NC}"
      ;;
    "lmstudio")
      echo -e "LM Studio API is accessible at: ${BLUE}http://$LM_STUDIO_HOST:$LM_STUDIO_PORT${NC}"
      ;;
    "localai")
      echo -e "LocalAI API is accessible at: ${BLUE}http://localhost:${LOCALAI_PORT}${NC}"
      echo -e "LocalAI Container: ${BLUE}$LOCALAI_NAME${NC}"
      ;;
  esac
  echo "========================================================"
  echo -e "To check network connectivity run: ${CYAN}./llm-launcher.sh --check-network${NC}"
  echo "========================================================"
}

# Function to stop containers and services that were started
stop_services() {
  info "Detecting active services..."
  local active_services=()
  local stopped_count=0
  local any_services_found=false
  
  # 1. Check OpenWebUI
  if docker ps -q -f "name=^/${OPEN_WEBUI_NAME}$" &>/dev/null; then
    active_services+=("OpenWebUI")
    any_services_found=true
  fi
  
  # 2. Check Ollama in container
  if docker ps -q -f "name=^/${OLLAMA_CONTAINER_NAME}$" &>/dev/null; then
    active_services+=("Ollama container")
    any_services_found=true
  fi
  
  # 3. Check LocalAI
  if docker ps -q -f "name=^/${LOCALAI_NAME}$" &>/dev/null; then
    active_services+=("LocalAI")
    any_services_found=true
  fi
  
  # 4. Check local Ollama started by the script
  # Use multiple methods to detect Ollama, not just systemd
  local service_manager=$(get_service_manager)
  case "$service_manager" in
    "systemd")
      if systemctl is-active ollama &>/dev/null; then
        active_services+=("Local Ollama (systemd)")
        any_services_found=true
      fi
      ;;
    "sysvinit")
      if service ollama status &>/dev/null; then
        active_services+=("Local Ollama (service)")
        any_services_found=true
      fi
      ;;
  esac
  
  # Check for manually started Ollama process
  if pgrep -f "ollama serve" &>/dev/null; then
    active_services+=("Local Ollama (process)")
    any_services_found=true
  fi
  
  if ! $any_services_found; then
    info "No services started by the script are currently running."
    return 0
  fi
  
  # Show active services
  info "Active services detected: ${active_services[*]}"
  info "Starting shutdown procedure..."
  
  # Stop active services
  for service in "${active_services[@]}"; do
    case "$service" in
      "OpenWebUI")
        info "Stopping OpenWebUI container..."
        if docker stop $OPEN_WEBUI_NAME &>/dev/null; then
          ((stopped_count++))
          success "OpenWebUI container stopped"
        else
          warning "Unable to stop OpenWebUI container"
        fi
        ;;
      
      "Ollama container")
        info "Stopping Ollama container..."
        if docker stop $OLLAMA_CONTAINER_NAME &>/dev/null; then
          ((stopped_count++))
          success "Ollama container stopped"
        else
          warning "Unable to stop Ollama container"
        fi
        ;;
      
      "LocalAI")
        info "Stopping LocalAI container..."
        if docker stop $LOCALAI_NAME &>/dev/null; then
          ((stopped_count++))
          success "LocalAI container stopped"
        else
          warning "Unable to stop LocalAI container"
        fi
        ;;
      
      "Local Ollama (systemd)"|"Local Ollama (service)"|"Local Ollama (process)")
        info "Stopping local Ollama..."
        if manage_service "ollama" "stop"; then
          ((stopped_count++))
          success "Local Ollama stopped"
        else
          warning "Unable to stop local Ollama"
        fi
        ;;
    esac
  done
  
  success "Operation completed: stopped $stopped_count services out of ${#active_services[@]}"
  return 0
}

# Main program execution flow
main() {
  echo "========================================================"
  echo "   🚀 OpenWebUI Configuration with LLM backend   "
  echo "========================================================"
  
  # Command-line flags
  local non_interactive=false
  local backend_choice=""
  
  # Check if running as root at the very beginning
  check_root
  
  # Process command-line arguments first
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        show_help
        exit 0
        ;;
      --setup-dirs)
        setup_directories
        exit 0
        ;;
      --create-config)
        create_default_config
        exit 0
        ;;
      --edit-config)
        edit_config || exit 1
        exit 0
        ;;
      --check-network)
        if [ -f "${CONFIG_FILE}" ]; then
          source "${CONFIG_FILE}"
        else
          error "Configuration file not found. Run --create-config first."
          exit 1
        fi
        check_network_status
        exit $?
        ;;
      --non-interactive)
        non_interactive=true
        ;;
      --backend=*)
        backend_choice="${1#*=}"
        ;;
      --stop)
        if [ -f "${CONFIG_FILE}" ]; then
          source "${CONFIG_FILE}"
        else
          error "Configuration file not found. Run --create-config first."
          exit 1
        fi
        stop_services
        exit $?
        ;;
      --verbose)
        VERBOSE=true
        ;;
      --debug)
        DEBUG=true
        VERBOSE=true
        ;;
      --detect-hardware)
        if [ -f "${CONFIG_FILE}" ]; then
          source "${CONFIG_FILE}"
        else
          warning "Configuration file not found. Creating default..."
          create_default_config
        fi
        detect_hardware
        exit 0
        ;;
      *)
        error "Unrecognized option: $1"
        show_help
        exit 1
        ;;
    esac
    shift
  done
  
  # Validate automated mode parameters
  if $non_interactive && [[ ! "$backend_choice" =~ ^(ollama|lmstudio|ollama-container|localai)$ ]]; then
    error "Invalid or missing backend choice for non-interactive mode"
    echo "Must specify one of: ollama, lmstudio, ollama-container, localai"
    exit 1
  fi
  
  # Verify environment and configuration
  if ! check_prerequisites; then
    exit 1
  fi
  
  # Detect hardware if configuration exists
  if [ -f "${CONFIG_FILE}" ]; then
    detect_hardware
  fi
  
  # Ensure Docker network exists
  if ! create_docker_network; then
    exit 1
  fi
  
  # Select LLM backend
  if ! $non_interactive; then
    # Interactive mode - show menu
    echo
    echo "Choose which backend you want to use:"
    echo "1 - Ollama on your local host"
    echo "2 - LM Studio on another PC ($LM_STUDIO_HOST:$LM_STUDIO_PORT)"
    echo "3 - Ollama in Docker container (with Intel GPU)"
    echo "4 - LocalAI with Intel acceleration (SYCL)"
    read -p "Enter your choice (1/2/3/4): " choice
    echo
    
    if [[ ! "$choice" =~ ^[1-4]$ ]]; then
      error "Invalid choice. Please enter a number from 1 to 4."
      exit 1
    fi
  else
    # Non-interactive mode - map backend name to number
    case "$backend_choice" in
      "ollama") choice=1 ;;
      "lmstudio") choice=2 ;;
      "ollama-container") choice=3 ;;
      "localai") choice=4 ;;
    esac
  fi
  
  # Set up selected backend
  local backend_setup_success=false
  case $choice in
    1) setup_local_ollama && backend_setup_success=true ;;
    2) setup_lm_studio && backend_setup_success=true ;;
    3) setup_ollama_container && backend_setup_success=true ;;
    4) setup_localai && backend_setup_success=true ;;
  esac
  
  if ! $backend_setup_success; then
    error "Backend configuration failed"
    exit 1
  fi
  
  # Launch UI container
  if ! start_open_webui; then
    exit 1
  fi
  
  # Test backend connectivity
  verify_connectivity
  
  # Display access information
  show_access_info
  
  exit 0
}

# Call main with all arguments
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi