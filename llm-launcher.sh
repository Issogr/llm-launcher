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
INTEL_GPU_DEVICE="iGPU"  # Default to iGPU if not detected otherwise

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

# Detect operating system
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "linux"
  else
    echo "unknown"
  fi
}

# Get system RAM in GB
get_system_memory() {
  local OS_TYPE=$(detect_os)
  local memory_gb
  
  if [[ "$OS_TYPE" == "macos" ]]; then
    if command -v sysctl &> /dev/null; then
      # Convert bytes to GB (1024^3)
      memory_gb=$(($(sysctl -n hw.memsize) / 1024 / 1024 / 1024))
      echo $memory_gb
      return 0
    fi
  else  # Linux
    if command -v free &> /dev/null; then
      memory_gb=$(free -g | awk '/^Mem:/{print $2}')
      echo $memory_gb
      return 0
    fi
  fi
  
  # If we couldn't determine memory, estimate based on CPU cores
  local cpu_cores=$(get_cpu_cores)
  if [[ $cpu_cores -le 4 ]]; then
    echo 4  # Minimum estimation
  else
    echo $((cpu_cores * 2))  # Estimate 2GB per core
  fi
}

# Get CPU cores count
get_cpu_cores() {
  local OS_TYPE=$(detect_os)
  
  if [[ "$OS_TYPE" == "macos" ]]; then
    if command -v sysctl &> /dev/null; then
      sysctl -n hw.ncpu
      return 0
    fi
  else  # Linux
    if command -v nproc &> /dev/null; then
      nproc --all
      return 0
    elif command -v grep &> /dev/null && [ -f /proc/cpuinfo ]; then
      grep -c processor /proc/cpuinfo
      return 0
    fi
  fi
  
  # Fallback to a reasonable minimum if cannot determine
  echo 2
}

# Cross-platform sed in-place replacement
sed_in_place() {
  local file="$1"
  local pattern="$2"
  local replacement="$3"
  
  local OS_TYPE=$(detect_os)
  if [[ "$OS_TYPE" == "macos" ]]; then
    sed -i '' "s|$pattern|$replacement|g" "$file"
  else
    sed -i "s|$pattern|$replacement|g" "$file"
  fi
}

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

# Detect GPU type and characteristics - improved version
detect_gpu() {
  local OS_TYPE=$(detect_os)
  local GPU_TYPE="NONE"
  local GPU_PARAMS=""
  local INTEL_GPU_DEVICE=""
  
  if [[ "$OS_TYPE" == "macos" ]]; then
    # GPU detection for macOS
    if command -v system_profiler &> /dev/null; then
      local GPU_INFO=$(system_profiler SPDisplaysDataType 2>/dev/null)
      if echo "$GPU_INFO" | grep -q "Vendor Name: Apple"; then
        GPU_TYPE="APPLE"
        debug "Apple Silicon GPU detected"
      elif echo "$GPU_INFO" | grep -q "Vendor Name: AMD"; then
        GPU_TYPE="AMD"
        debug "AMD GPU detected in macOS"
      elif echo "$GPU_INFO" | grep -q "Vendor Name: Intel"; then
        GPU_TYPE="INTEL"
        INTEL_GPU_DEVICE="iGPU"
        debug "Intel GPU detected in macOS"
      else
        debug "No specific GPU type detected in macOS"
      fi
    fi
  else
    # Linux GPU detection
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
        
        # Determine specific Intel GPU type
        INTEL_GPU_DEVICE="iGPU"  # Start with a reasonable baseline
        
        if [[ $GPU_INFO =~ [Mm][Aa][Xx].[Ss][Ee][Rr][Ii][Ee][Ss] ]]; then
          INTEL_GPU_DEVICE="Max"
          debug "Intel Max Series GPU detected"
        elif [[ $GPU_INFO =~ [Ff][Ll][Ee][Xx].[Ss][Ee][Rr][Ii][Ee][Ss] ]]; then
          INTEL_GPU_DEVICE="Flex"
          debug "Intel Flex Series GPU detected"
        elif [[ $GPU_INFO =~ [Aa][Rr][Cc] ]]; then
          INTEL_GPU_DEVICE="Arc"
          debug "Intel Arc GPU detected"
        else
          debug "Intel integrated GPU detected, using iGPU as device type"
        fi
        
        debug "Intel GPU detected, DEVICE=${INTEL_GPU_DEVICE}"
      else
        debug "No supported GPU detected via lspci"
      fi
    else
      # Try alternative GPU detection methods if lspci isn't available
      if command -v glxinfo &>/dev/null; then
        local GLXINFO=$(glxinfo 2>/dev/null | grep -i "vendor\|renderer")
        if [[ $GLXINFO =~ [Nn][Vv][Ii][Dd][Ii][Aa] ]]; then
          GPU_TYPE="NVIDIA"
          GPU_PARAMS="--gpus all"
          debug "NVIDIA GPU detected via glxinfo"
        elif [[ $GLXINFO =~ [Aa][Mm][Dd] ]]; then
          GPU_TYPE="AMD"
          GPU_PARAMS="--device=/dev/dri"
          debug "AMD GPU detected via glxinfo"
        elif [[ $GLXINFO =~ [Ii][Nn][Tt][Ee][Ll] ]]; then
          GPU_TYPE="INTEL"
          INTEL_GPU_DEVICE="iGPU"
          GPU_PARAMS="--device=/dev/dri"
          debug "Intel GPU detected via glxinfo"
        fi
      elif [ -d "/sys/class/drm" ]; then
        # Check Linux DRM subsystem
        if grep -q "i915" /sys/class/drm/*/device/driver 2>/dev/null; then
          GPU_TYPE="INTEL"
          INTEL_GPU_DEVICE="iGPU"
          GPU_PARAMS="--device=/dev/dri"
          debug "Intel GPU detected via DRM subsystem"
        elif grep -q "amdgpu" /sys/class/drm/*/device/driver 2>/dev/null; then
          GPU_TYPE="AMD"
          GPU_PARAMS="--device=/dev/dri"
          debug "AMD GPU detected via DRM subsystem"
        elif grep -q "nvidia" /sys/class/drm/*/device/driver 2>/dev/null; then
          GPU_TYPE="NVIDIA"
          GPU_PARAMS="--gpus all"
          debug "NVIDIA GPU detected via DRM subsystem"
        fi
      else
        debug "Could not detect GPU using available methods"
      fi
    fi
  fi
  
  # Return results as JSON-like string that can be parsed
  echo "GPU_TYPE=\"$GPU_TYPE\" GPU_PARAMS=\"$GPU_PARAMS\" INTEL_GPU_DEVICE=\"$INTEL_GPU_DEVICE\""
}

# Check Docker permissions
check_docker_permissions() {
  debug "Checking Docker permissions..."
  
  # First check if docker command exists
  if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Please install it before continuing."
    return 1
  fi
  
  # Detect OS type
  local OS_TYPE=$(detect_os)
  
  # Check for Orb Stack on macOS
  if [[ "$OS_TYPE" == "macos" ]]; then
    if [ -d "/Applications/OrbStack.app" ] || [ -f "$HOME/.orbstack/bin/docker" ]; then
      info "OrbStack detected on macOS"
      
      # Ensure OrbStack's Docker is in the PATH if not already
      if ! docker info &>/dev/null; then
        if [ -f "$HOME/.orbstack/bin/docker" ]; then
          export PATH="$HOME/.orbstack/bin:$PATH"
          info "Added OrbStack's Docker to PATH"
        fi
      fi
      
      # Try again after PATH adjustment
      if docker info &>/dev/null; then
        success "OrbStack Docker configuration verified"
        return 0
      else
        error "OrbStack Docker seems to be installed but not functioning properly."
        error "Please ensure OrbStack is running before continuing."
        return 1
      fi
    fi
  fi
  
  # Standard Docker check (original code)
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
      if [[ "$OS_TYPE" == "macos" ]]; then
        error "If you're using OrbStack, make sure it's running and properly configured."
        error "You may need to restart OrbStack, or restart your terminal to update your PATH."
      else
        error "Please ensure Docker is properly installed and your user has proper permissions."
      fi
      return 1
    fi
  fi
  
  return 0
}

# Hardware detection and automatic resource allocation - completely dynamic
detect_hardware() {
  info "Detecting hardware capabilities..."
  
  # Get memory and CPU cores dynamically
  local TOTAL_MEM=$(get_system_memory)
  local CPU_CORES=$(get_cpu_cores)
  
  # Calculate recommended values based on available resources
  if [[ $TOTAL_MEM -lt 4 ]]; then
    warning "Very low memory detected: ${TOTAL_MEM}G. Performance will be severely limited."
    RECOMMENDED_MEM="${TOTAL_MEM}G"
    RECOMMENDED_SHM="1g"  # Minimum shared memory
  elif [[ $TOTAL_MEM -lt 8 ]]; then
    warning "Low memory detected: ${TOTAL_MEM}G. This may impact performance."
    RECOMMENDED_MEM="${TOTAL_MEM}G"
    RECOMMENDED_SHM="$((TOTAL_MEM / 2))g"  # Half of available memory
  else
    # Allocate 80% of memory for container, but cap at 64GB
    local PERCENT_MEM=$((TOTAL_MEM * 80 / 100))
    if [[ $PERCENT_MEM -gt 64 ]]; then
      RECOMMENDED_MEM="64G"  # Cap at 64GB
    else
      RECOMMENDED_MEM="${PERCENT_MEM}G"
    fi
    
    # For larger memory systems, limit shared memory to 16GB
    if [[ $TOTAL_MEM -gt 32 ]]; then
      RECOMMENDED_SHM="16g"
    else
      RECOMMENDED_SHM="$((TOTAL_MEM * 50 / 100))g"  # 50% of available memory
    fi
  fi
  
  # Calculate optimal thread count based on CPU cores
  if [[ $CPU_CORES -le 2 ]]; then
    RECOMMENDED_THREADS=$CPU_CORES  # Use all cores if only 1-2 available
  elif [[ $CPU_CORES -le 6 ]]; then
    RECOMMENDED_THREADS=$((CPU_CORES - 1))  # Leave 1 core for system
  else
    RECOMMENDED_THREADS=$((CPU_CORES - 2))  # Leave 2 cores for system
  fi
  
  # Detect GPU - use the improved, fully dynamic function
  local GPU_DETECTION=$(detect_gpu)
  eval "$GPU_DETECTION"  # This sets GPU_TYPE, GPU_PARAMS, and INTEL_GPU_DEVICE
  
  # Print hardware summary
  info "System resources detected:"
  info "  - Memory: ${TOTAL_MEM}G (Recommended usage: ${RECOMMENDED_MEM})"
  info "  - CPU Cores: ${CPU_CORES} (Recommended threads: ${RECOMMENDED_THREADS})"
  info "  - GPU Type: ${GPU_TYPE}"
  if [[ "$GPU_TYPE" == "INTEL" ]]; then
    info "  - Intel GPU Device: ${INTEL_GPU_DEVICE}"
  fi
  
  # Update config values if they exist
  if [ -f "${CONFIG_FILE}" ]; then
    source "${CONFIG_FILE}"
    # Only suggest changes if values are significantly different
    if [[ ${MEMORY_LIMIT%[A-Za-z]} -lt ${RECOMMENDED_MEM%[A-Za-z]} ]]; then
      if prompt_with_timeout "${YELLOW}Current memory limit (${MEMORY_LIMIT}) is less than recommended (${RECOMMENDED_MEM}). Update? (y/n):${NC}" 10 "n"; then
        sed_in_place "${CONFIG_FILE}" "^MEMORY_LIMIT=.*" "MEMORY_LIMIT=\"${RECOMMENDED_MEM}\""
        MEMORY_LIMIT="${RECOMMENDED_MEM}"
      fi
    fi
    if [[ ${SHM_SIZE%[A-Za-z]} -lt ${RECOMMENDED_SHM%[A-Za-z]} ]]; then
      if prompt_with_timeout "${YELLOW}Current shared memory (${SHM_SIZE}) is less than recommended (${RECOMMENDED_SHM}). Update? (y/n):${NC}" 10 "n"; then
        sed_in_place "${CONFIG_FILE}" "^SHM_SIZE=.*" "SHM_SIZE=\"${RECOMMENDED_SHM}\""
        SHM_SIZE="${RECOMMENDED_SHM}"
      fi
    fi
    # Update extra flags for LocalAI with more sophisticated thread detection
    local CURRENT_THREADS=1
    if [[ "${LOCALAI_EXTRA_FLAGS}" =~ --threads[[:space:]]+([0-9]+) ]]; then
      CURRENT_THREADS="${BASH_REMATCH[1]}"
    fi
    
    if [[ $CURRENT_THREADS -ne $RECOMMENDED_THREADS ]]; then
      if prompt_with_timeout "${YELLOW}Update LocalAI thread count from ${CURRENT_THREADS} to ${RECOMMENDED_THREADS}? (y/n):${NC}" 10 "n"; then
        # Remove any existing threads parameter and add our recommended one
        local NEW_FLAGS="${LOCALAI_EXTRA_FLAGS}"
        NEW_FLAGS=$(echo "$NEW_FLAGS" | sed -E 's/--threads[[:space:]]+[0-9]+//')
        NEW_FLAGS="$NEW_FLAGS --threads ${RECOMMENDED_THREADS}"
        # Clean up any duplicate spaces
        NEW_FLAGS=$(echo "$NEW_FLAGS" | sed -E 's/[[:space:]]+/ /g' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        
        sed_in_place "${CONFIG_FILE}" "^LOCALAI_EXTRA_FLAGS=.*" "LOCALAI_EXTRA_FLAGS=\"${NEW_FLAGS}\""
        LOCALAI_EXTRA_FLAGS="${NEW_FLAGS}"
      fi
    fi
  fi
  
  # Export variables for use by other functions
  export RECOMMENDED_MEM
  export RECOMMENDED_SHM
  export RECOMMENDED_THREADS
  export GPU_TYPE
  export GPU_PARAMS
  export INTEL_GPU_DEVICE
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

# Function to create the default configuration file - fully dynamic
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
  
  info "Creating the default configuration file with dynamically detected settings..."
  
  # Get system resources - fully dynamic
  local DETECTED_MEM=$(get_system_memory)
  local CPU_CORES=$(get_cpu_cores)
  
  # Calculate memory limits based on available resources
  local MEM_LIMIT
  local SHARE_MEM
  
  if [[ $DETECTED_MEM -lt 4 ]]; then
    MEM_LIMIT="${DETECTED_MEM}G"
    SHARE_MEM="1g"
  elif [[ $DETECTED_MEM -lt 8 ]]; then
    MEM_LIMIT="${DETECTED_MEM}G"
    SHARE_MEM="$((DETECTED_MEM / 2))g"
  else
    local PERCENT_MEM=$((DETECTED_MEM * 80 / 100))
    if [[ $PERCENT_MEM -gt 64 ]]; then
      MEM_LIMIT="64G"
    else
      MEM_LIMIT="${PERCENT_MEM}G"
    fi
    
    if [[ $DETECTED_MEM -gt 32 ]]; then
      SHARE_MEM="16g"
    else
      SHARE_MEM="$((DETECTED_MEM * 50 / 100))g"
    fi
  fi
  
  # Calculate thread count based on CPU cores
  local THREADS
  if [[ $CPU_CORES -le 2 ]]; then
    THREADS=$CPU_CORES
  elif [[ $CPU_CORES -le 6 ]]; then
    THREADS=$((CPU_CORES - 1))
  else
    THREADS=$((CPU_CORES - 2))
  fi
  
  # Detect LM Studio port availability
  local LM_STUDIO_PORT="1234"
  # Check if port 1234 is already in use on a different machine
  if command -v nc &> /dev/null && command -v grep &> /dev/null; then
    if nc -z localhost 1234 &>/dev/null; then
      info "Default LM Studio port 1234 is available on localhost"
    else
      info "Checking network for potential LM Studio servers..."
      # Try to discover LM Studio on the local network
      local found_server=false
      local found_ip=""
      
      # Only attempt network scan if nmap is available
      if command -v nmap &> /dev/null; then
        # Get local IP range
        local IP_BASE=""
        if command -v ip &> /dev/null; then
          IP_BASE=$(ip route | grep default | awk '{print $3}' | sed 's/\.[0-9]*$/./')
        elif command -v ifconfig &> /dev/null; then
          IP_BASE=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | sed 's/\.[0-9]*$/./')
        fi
        
        if [ -n "$IP_BASE" ]; then
          info "Scanning network for LM Studio on port 1234..."
          local SCAN_RESULT=$(nmap -p 1234 --open ${IP_BASE}0/24 -T4 --host-timeout 2s 2>/dev/null)
          local POSSIBLE_HOSTS=$(echo "$SCAN_RESULT" | grep -B 4 "1234/tcp open" | grep "Nmap scan report" | awk '{print $NF}')
          
          if [ -n "$POSSIBLE_HOSTS" ]; then
            # Take the first result
            found_ip=$(echo "$POSSIBLE_HOSTS" | head -n 1)
            found_server=true
          fi
        fi
      fi
      
      if $found_server; then
        LM_STUDIO_HOST=$found_ip
        info "Potential LM Studio server found at $LM_STUDIO_HOST:$LM_STUDIO_PORT"
      else
        LM_STUDIO_HOST="192.168.1.100"  # Reasonable guess for a local network
        info "No LM Studio server discovered automatically. Using $LM_STUDIO_HOST as a placeholder."
      fi
    fi
  else
    LM_STUDIO_HOST="192.168.1.100"  # Use a reasonable default
  fi
  
  # Create the configuration file with dynamic values
  cat > "${CONFIG_FILE}" << EOF
# Configuration for llm-launcher.sh
# Modify these parameters according to your needs
# Generated dynamically based on system resources

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
LM_STUDIO_HOST="$LM_STUDIO_HOST"
LM_STUDIO_PORT="$LM_STUDIO_PORT"

# LocalAI with Intel acceleration
LOCALAI_IMAGE="localai/localai:v2.27.0-sycl-f16-ffmpeg"
LOCALAI_NAME="localai-container"
LOCALAI_PORT="8080"
LOCALAI_MODEL="gemma-3-4b-it-qat"
LOCALAI_EXTRA_FLAGS="--threads ${THREADS}"

# Memory requirements (detected dynamically from system)
MEMORY_LIMIT="${MEM_LIMIT}"
SHM_SIZE="${SHARE_MEM}"

# Network diagnostics
NETWORK_DIAGNOSTIC_TIMEOUT="2" # seconds for timeout in connectivity tests
EOF

  success "Configuration file created at: ${CONFIG_FILE} with dynamically detected settings"
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
      
      # Special handling for macOS with OrbStack
      local OS_TYPE=$(detect_os)
      if [[ "$OS_TYPE" == "macos" && "$LM_STUDIO_HOST" == "localhost" ]]; then
        # On macOS with localhost, configure for proper container-to-host networking
        WEBUI_ENV_PARAMS=(
          "-e OPENAI_API_KEY=$OPENAI_API_KEY"
          "-e OPENAI_API_BASE_URL=http://host.docker.internal:$LM_STUDIO_PORT/v1"
        )
        EXTRA_PARAMS="--add-host=host.docker.internal:host-gateway"
      else
        # Standard configuration
        WEBUI_ENV_PARAMS=(
          "-e OPENAI_API_KEY=$OPENAI_API_KEY"
          "-e OPENAI_API_BASE_URL=$OPENAI_API_BASE_URL"
        )
      fi
      
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
      # Note: status returns 0 if active, 3 if inactive, 4 if failed, any other value if it does not exist
      systemctl status $service_name &>/dev/null
      local retval=$?
      if [ $retval -eq 0 ] || [ $retval -eq 3 ] || [ $retval -eq 4 ]; then
        debug "Servizio $service_name trovato in systemd (stato: $retval)"
        sudo systemctl $action $service_name
        return $?
      else
        # Prova anche con .service appeso
        systemctl status $service_name.service &>/dev/null
        local retval=$?
        if [ $retval -eq 0 ] || [ $retval -eq 3 ] || [ $retval -eq 4 ]; then
          debug "Servizio $service_name.service trovato in systemd (stato: $retval)"
          sudo systemctl $action $service_name.service
          return $?
        else
          debug "Servizio $service_name non trovato in systemd"
        fi
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
  # Check if we're on macOS
  local OS_TYPE=$(detect_os)
  if [[ "$OS_TYPE" == "macos" ]]; then
    info "macOS detected, using localhost for LM Studio..."
    LM_STUDIO_HOST="localhost"
  fi

  info "Configuring to use LM Studio on $LM_STUDIO_HOST:$LM_STUDIO_PORT..."
  
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
  
  # Set the appropriate GPU device parameter for Intel GPUs
  local gpu_device_param="iGPU"  # Start with a reasonable baseline
  if [[ "$GPU_TYPE" == "INTEL" && -n "$INTEL_GPU_DEVICE" ]]; then
    gpu_device_param="$INTEL_GPU_DEVICE"
  fi
  
  # Start the Ollama container using the common function
  if ! start_container "$OLLAMA_CONTAINER_NAME" \
    "$OLLAMA_CONTAINER_IMAGE" \
    "-p $OLLAMA_CONTAINER_PORT:11434" \
    "bash -c 'cd /llm/scripts && source ipex-llm-init --gpu --device ${gpu_device_param} && bash start-ollama.sh && tail -f /dev/null'" \
    "$GPU_PARAMS" \
    "-v ${LLM_BASE_DIR}/models/ollama:/root/.ollama/models" \
    "-e OLLAMA_HOST=0.0.0.0" \
    "-e DEVICE=${gpu_device_param}" \
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

# Check if a container is running
is_container_running() {
  docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q "true"
  return $?
}

# Stop a container and verify it's actually stopped
stop_container() {
  local name="$1"
  
  docker stop "$name" &>/dev/null
  sleep 1 # Brief pause to allow Docker to update container state
  if ! is_container_running "$name"; then
    ((stopped_count++))
    success "$name container stopped"
    return 0
  else
    warning "$name container still appears to be running"
    return 1
  fi
}

# Check if the Ollama service is running and distinguish between local and container
is_local_ollama_running() {
  # First check if the Ollama container is running - if it is, then any API
  # responses are likely coming from the container, not a local installation
  if is_container_running "$OLLAMA_CONTAINER_NAME"; then
    debug "Ollama container is running, assuming API responses are from container"
    return 1
  fi
  
  # Now check if API responds
  if ! curl -s --connect-timeout 2 http://localhost:11434/api/version &>/dev/null; then
    debug "Ollama API is not responding"
    return 1
  fi
  
  # At this point API is responding and container is not running, so it must be local
  debug "Ollama API is responding and container is not running, so it's the local service"
  
  # Double-check with service manager or process
  local service_manager=$(get_service_manager)
  if [[ "$service_manager" == "systemd" ]] && systemctl is-active --quiet ollama; then
    debug "Confirmed local Ollama is running via systemd"
    return 0
  elif [[ "$service_manager" == "sysvinit" ]] && service ollama status 2>/dev/null | grep -q "running"; then
    debug "Confirmed local Ollama is running via service"
    return 0
  elif pgrep -x "ollama" &>/dev/null || pgrep -f "ollama serve" &>/dev/null; then
    debug "Confirmed local Ollama is running as process"
    return 0
  fi
  
  # If we get here, API is responding but we can't confirm local service
  debug "API is responding but couldn't confirm local service, assuming not local"
  return 1
}

# Stop Ollama regardless of how it was started
stop_ollama() {
  local was_running=false
  
  # Try service manager first if available
  local service_manager=$(get_service_manager)
  if [[ "$service_manager" == "systemd" ]] && systemctl is-active --quiet ollama; then
    was_running=true
    sudo systemctl stop ollama &>/dev/null
  elif [[ "$service_manager" == "sysvinit" ]] && service ollama status 2>/dev/null | grep -q "running"; then
    was_running=true
    sudo service ollama stop &>/dev/null
  fi
  
  # Try process kill if needed
  if pgrep -x "ollama" &>/dev/null || pgrep -f "ollama serve" &>/dev/null; then
    was_running=true
    pkill -TERM -x "ollama" 2>/dev/null
    pkill -TERM -f "ollama serve" 2>/dev/null
    sleep 2
    # Force kill if still running
    pkill -KILL -x "ollama" 2>/dev/null
    pkill -KILL -f "ollama serve" 2>/dev/null
  fi
  
  # Verify Ollama is truly stopped
  if ! curl -s --connect-timeout 2 http://localhost:11434/api/version &>/dev/null || is_container_running "$OLLAMA_CONTAINER_NAME"; then
    # Either API is down or container is running (which means API is from container)
    if $was_running; then
      ((stopped_count++))
      success "Local Ollama stopped"
      return 0
    fi
  else
    warning "Failed to stop local Ollama - API is still responding"
    return 1
  fi
}

# Main function to stop services
stop_services() {
  info "Detecting active services..."
  local active_services=()
  local stopped_count=0
  
  # Container checks - always do these first
  local containers=("$OPEN_WEBUI_NAME:OpenWebUI" "$OLLAMA_CONTAINER_NAME:Ollama container" "$LOCALAI_NAME:LocalAI")
  for container_def in "${containers[@]}"; do
    local container_name="${container_def%%:*}"
    local container_label="${container_def#*:}"
    
    if is_container_running "$container_name"; then
      active_services+=("$container_label")
      debug "$container_label is running"
    fi
  done
  
  # Check Local Ollama service AFTER checking containers
  if is_local_ollama_running; then
    active_services+=("Local Ollama")
    debug "Local Ollama is running (not the container)"
  fi
  
  # If no services found, exit early
  if [ ${#active_services[@]} -eq 0 ]; then
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
        stop_container "$OPEN_WEBUI_NAME"
        ;;
      "Ollama container")
        info "Stopping Ollama container..."
        stop_container "$OLLAMA_CONTAINER_NAME"
        ;;
      "LocalAI")
        info "Stopping LocalAI container..."
        stop_container "$LOCALAI_NAME"
        ;;
      "Local Ollama")
        info "Stopping local Ollama..."
        stop_ollama
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
    echo "2 - LM Studio (uses localhost on macOS, $LM_STUDIO_HOST on other systems)"
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