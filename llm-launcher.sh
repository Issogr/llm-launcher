#!/bin/bash
# ===========================================================
# LLM Launcher - Utility to configure and start OpenWebUI with various LLM backends
# 
# Supported backend options:
# - Local Ollama
# - Remote LM Studio server
# - Ollama in Docker container with Intel GPU acceleration
# - Local llama.cpp server
# - LocalAI with Intel SYCL acceleration
# ===========================================================

# Enable better error detection and handling
set -o pipefail
trap cleanup EXIT

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

# Executed when script exits for any reason
cleanup() {
  # Can be extended with container cleanup if needed
  return 0
}

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
  echo "  --non-interactive         Run with default options (must specify backend with --backend)"
  echo "  --backend=TYPE            Specify backend type: ollama, lmstudio, ollama-container, llama-cpp, localai"
  echo
  echo "Standard usage:"
  echo "  ./llm-launcher.sh          Launch normally using existing configurations"
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
    "${LLM_BASE_DIR}/models/llama_cpp"   # llama.cpp models
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

# llama.cpp local
LLAMA_CPP_HOST="localhost"
LLAMA_CPP_PORT="8080"

# LocalAI with Intel acceleration
LOCALAI_IMAGE="localai/localai:v2.27.0-sycl-f16-ffmpeg"
LOCALAI_NAME="localai-container"
LOCALAI_PORT="8080"
LOCALAI_MODEL="gemma-3-4b-it-qat"
LOCALAI_EXTRA_FLAGS="--threads 4"

# Memory requirements (in gigabytes)
MEMORY_LIMIT="30G"
SHM_SIZE="20g"

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
  
  # Check if docker is installed
  if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Install it before running this script."
    return 1
  fi
  
  # Check if docker is running
  if ! docker info &> /dev/null; then
    error "Docker service is not running. Start it with 'sudo systemctl start docker'."
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
  
  # Try to download latest version with 30s timeout
  if timeout 30s docker pull "$image_name"; then
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
        
        # Simplified service startup logic
        if systemctl --version &>/dev/null && systemctl list-unit-files | grep -q ollama; then
          sudo systemctl start ollama
        else
          mkdir -p ${LLM_BASE_DIR}/logs
          nohup ollama serve > ${LLM_BASE_DIR}/logs/ollama.log 2>&1 &
        fi
        
        info "Waiting for Ollama to start (5 seconds)..."
        sleep 5
        
        if ! curl -s --connect-timeout 2 http://localhost:11434/api/version > /dev/null; then
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
  
  # Configure environment variables for OpenWebUI
  OLLAMA_HOST_VAR="host.docker.internal"
  OLLAMA_URL_VAR="http://host.docker.internal:11434"
  EXTRA_PARAMS="--add-host=host.docker.internal:host-gateway"
  
  # Prepare parameters for OpenWebUI
  WEBUI_ENV_PARAMS=(
    "-e OLLAMA_BASE_URL=$OLLAMA_URL_VAR"
    "-e OLLAMA_API_HOST=$OLLAMA_HOST_VAR"
    "-e OLLAMA_API_PORT=11434"
  )
  
  # Save the backend type for final verification
  BACKEND_TYPE="ollama"
  BACKEND_URL="http://localhost:11434"
  
  return 0
}

# Function to configure remote LM Studio (option 2)
setup_lm_studio() {
  info "Configuring to use LM Studio on another PC ($LM_STUDIO_HOST:$LM_STUDIO_PORT)..."
  
  # Configuration for LM Studio (OpenAI compatible API)
  OPENAI_API_KEY="lm-studio"  # Any value works
  OPENAI_API_HOST=$LM_STUDIO_HOST
  OPENAI_API_PORT=$LM_STUDIO_PORT
  OPENAI_API_BASE_URL="http://$LM_STUDIO_HOST:$LM_STUDIO_PORT/v1"
  EXTRA_PARAMS=""
  
  # Check connection with timeout
  if ! curl -s --connect-timeout 3 "http://$LM_STUDIO_HOST:$LM_STUDIO_PORT/v1/models" > /dev/null; then
    warning "Cannot connect to LM Studio on $LM_STUDIO_HOST:$LM_STUDIO_PORT"
    warning "Make sure it is running and accessible from the network."
    
    if ! prompt_with_timeout "${YELLOW}Continue anyway? (y/n):${NC}" 10; then
      return 1
    fi
  else
    success "Connection to LM Studio on remote PC verified"
  fi
  
  # Prepare parameters for OpenWebUI
  WEBUI_ENV_PARAMS=(
    "-e OPENAI_API_KEY=$OPENAI_API_KEY"
    "-e OPENAI_API_HOST=$OPENAI_API_HOST"
    "-e OPENAI_API_PORT=$OPENAI_API_PORT"
    "-e OPENAI_API_BASE_URL=$OPENAI_API_BASE_URL"
  )
  
  # Save the backend type for final verification
  BACKEND_TYPE="lmstudio"
  BACKEND_URL="http://$LM_STUDIO_HOST:$LM_STUDIO_PORT/v1/models"
  
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
  
  # Start the Ollama container with simplified command
  info "Starting container $OLLAMA_CONTAINER_NAME..."
  if ! docker run -itd \
    -p $OLLAMA_CONTAINER_PORT:11434 \
    --device=/dev/dri \
    -v "${LLM_BASE_DIR}/models/ollama:/root/.ollama/models" \
    -e OLLAMA_HOST=0.0.0.0 \
    --memory="${MEMORY_LIMIT}" \
    --name=$OLLAMA_CONTAINER_NAME \
    --shm-size="${SHM_SIZE}" \
    --network=$DOCKER_NETWORK \
    $OLLAMA_CONTAINER_IMAGE \
    bash -c 'ln -s /llm/ollama/ollama /usr/local/bin/ollama && cd /llm/scripts && source ipex-llm-init --gpu --device iGPU && bash start-ollama.sh && tail -f /dev/null'; then
    
    error "Unable to start container $OLLAMA_CONTAINER_NAME"
    return 1
  fi
  
  # Wait for Ollama to start
  info "Waiting for Ollama to start in the container (15 seconds)..."
  sleep 15
  
  # Configure environment variables for OpenWebUI
  OLLAMA_HOST_VAR=$OLLAMA_CONTAINER_NAME
  OLLAMA_URL_VAR="http://$OLLAMA_CONTAINER_NAME:11434"
  EXTRA_PARAMS=""
  
  # Prepare parameters for OpenWebUI
  WEBUI_ENV_PARAMS=(
    "-e OLLAMA_BASE_URL=$OLLAMA_URL_VAR"
    "-e OLLAMA_API_HOST=$OLLAMA_HOST_VAR"
    "-e OLLAMA_API_PORT=11434"
  )
  
  # Save the backend type for final verification
  BACKEND_TYPE="ollama-container"
  BACKEND_URL="$OLLAMA_URL_VAR/api/version"
  
  success "Ollama container started successfully"
  return 0
}

# Function to configure local llama.cpp (option 4)
setup_llama_cpp() {
  info "Configuring connection to local llama.cpp ($LLAMA_CPP_HOST:$LLAMA_CPP_PORT)..."
  
  # Configuration for llama.cpp (OpenAI compatible API)
  OPENAI_API_KEY="llama-cpp"  # Any value works
  OPENAI_API_HOST="host.docker.internal"
  OPENAI_API_PORT=$LLAMA_CPP_PORT
  OPENAI_API_BASE_URL="http://host.docker.internal:$LLAMA_CPP_PORT/v1"
  EXTRA_PARAMS="--add-host=host.docker.internal:host-gateway"
  
  # Check connection with timeout
  if ! curl -s --connect-timeout 3 "http://$LLAMA_CPP_HOST:$LLAMA_CPP_PORT/v1/models" > /dev/null; then
    warning "Cannot connect to llama.cpp on $LLAMA_CPP_HOST:$LLAMA_CPP_PORT"
    warning "Make sure llama.cpp is running with the server enabled"
    
    if ! prompt_with_timeout "${YELLOW}Continue anyway? (y/n):${NC}" 10; then
      return 1
    fi
  else
    success "Connection to llama.cpp on local host verified"
  fi
  
  # Prepare parameters for OpenWebUI
  WEBUI_ENV_PARAMS=(
    "-e OPENAI_API_KEY=$OPENAI_API_KEY"
    "-e OPENAI_API_HOST=$OPENAI_API_HOST"
    "-e OPENAI_API_PORT=$OPENAI_API_PORT"
    "-e OPENAI_API_BASE_URL=$OPENAI_API_BASE_URL"
  )
  
  # Save the backend type for final verification
  BACKEND_TYPE="llama-cpp"
  BACKEND_URL="http://$LLAMA_CPP_HOST:$LLAMA_CPP_PORT/v1/models"
  
  return 0
}

# Function to configure and start LocalAI with Intel acceleration (option 5)
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
  
  # Start the LocalAI container with simplified command
  info "Starting container $LOCALAI_NAME with model $LOCALAI_MODEL..."
  if ! docker run -itd \
    -p ${LOCALAI_PORT}:8080 \
    --device=/dev/dri \
    -v "${LLM_BASE_DIR}/models/localai:/build/models" \
    -e DEBUG=true \
    -e MODELS_PATH=/build/models \
    -e THREADS=1 \
    --name=$LOCALAI_NAME \
    --shm-size="${SHM_SIZE}" \
    --network=$DOCKER_NETWORK \
    $LOCALAI_IMAGE \
    $LOCALAI_MODEL $LOCALAI_EXTRA_FLAGS; then
    
    error "Unable to start container $LOCALAI_NAME"
    return 1
  fi
  
  # Wait for LocalAI to start
  info "Waiting for LocalAI to start in the container (15 seconds)..."
  sleep 15
  
  # Configure environment variables for OpenWebUI
  OPENAI_API_KEY="localai"
  OPENAI_API_BASE_URL="http://$LOCALAI_NAME:8080/v1"
  
  # Prepare parameters for OpenWebUI
  WEBUI_ENV_PARAMS=(
    "-e OPENAI_API_KEY=$OPENAI_API_KEY"
    "-e OPENAI_API_BASE_URL=$OPENAI_API_BASE_URL"
  )
  
  # Set extra params to empty as we're using Docker networking
  EXTRA_PARAMS=""
  
  # Save the backend type for final verification
  BACKEND_TYPE="localai"
  BACKEND_URL="http://localhost:${LOCALAI_PORT}/v1/models"
  
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
  
  info "Starting container $OPEN_WEBUI_NAME..."
  
  # Use array for Docker run command (cleaner than string concatenation)
  local docker_args=(
    "run" "-d"
    "-p" "${OPEN_WEBUI_PORT}:8080"
    "-v" "${LLM_BASE_DIR}/data/open-webui:/app/backend/data"
    "--name" "$OPEN_WEBUI_NAME"
    "--network=$DOCKER_NETWORK"
  )
  
  # Add all environment variables from backend setup
  for param in "${WEBUI_ENV_PARAMS[@]}"; do
    docker_args+=($param)
  done
  
  # Add host mapping or other extra parameters if needed
  if [ -n "$EXTRA_PARAMS" ]; then
    local extra_args=($EXTRA_PARAMS)
    docker_args+=("${extra_args[@]}")
  fi
  
  # Add the image name as the final parameter
  docker_args+=("$OPEN_WEBUI_IMAGE")
  
  # Launch container
  if ! docker "${docker_args[@]}"; then
    error "Unable to start container $OPEN_WEBUI_NAME"
    return 1
  fi
  
  success "OpenWebUI started successfully"
  return 0
}

# Test connectivity between OpenWebUI and the selected LLM backend
verify_connectivity() {
  info "Verifying connectivity between OpenWebUI and the backend..."
  
  # Allow container time to initialize networking
  sleep 5
  
  # Determine appropriate API endpoint to test based on backend type
  local test_url=""
  local test_container=$OPEN_WEBUI_NAME
  
  case "$BACKEND_TYPE" in
    "ollama")
      test_url="$OLLAMA_URL_VAR/api/version"
      ;;
    "ollama-container")
      test_url="$BACKEND_URL"
      ;;
    "lmstudio"|"llama-cpp")
      test_url="$BACKEND_URL"
      ;;
    "localai")
      test_url="${OPENAI_API_BASE_URL}/models"
      ;;
  esac
  
  # Test API connectivity with timeout to prevent hanging
  if docker exec $test_container timeout 5 curl -s "$test_url" > /dev/null; then
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
    "llama-cpp")
      echo -e "llama.cpp API is accessible at: ${BLUE}http://$LLAMA_CPP_HOST:$LLAMA_CPP_PORT${NC}"
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

# Main program execution flow
main() {
  echo "========================================================"
  echo "   🚀 OpenWebUI Configuration with LLM backend   "
  echo "========================================================"
  
  # Command-line flags
  local non_interactive=false
  local backend_choice=""
  
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
      *)
        error "Unrecognized option: $1"
        show_help
        exit 1
        ;;
    esac
    shift
  done
  
  # Validate automated mode parameters
  if $non_interactive && [[ ! "$backend_choice" =~ ^(ollama|lmstudio|ollama-container|llama-cpp|localai)$ ]]; then
    error "Invalid or missing backend choice for non-interactive mode"
    echo "Must specify one of: ollama, lmstudio, ollama-container, llama-cpp, localai"
    exit 1
  fi
  
  # Verify environment and configuration
  if ! check_prerequisites; then
    exit 1
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
    echo "4 - Local llama.cpp on $LLAMA_CPP_HOST:$LLAMA_CPP_PORT (OpenAI compatible)"
    echo "5 - LocalAI with Intel acceleration (SYCL)"
    read -p "Enter your choice (1/2/3/4/5): " choice
    echo
    
    if [[ ! "$choice" =~ ^[1-5]$ ]]; then
      error "Invalid choice. Please enter a number from 1 to 5."
      exit 1
    fi
  else
    # Non-interactive mode - map backend name to number
    case "$backend_choice" in
      "ollama") choice=1 ;;
      "lmstudio") choice=2 ;;
      "ollama-container") choice=3 ;;
      "llama-cpp") choice=4 ;;
      "localai") choice=5 ;;
    esac
  fi
  
  # Set up selected backend
  local backend_setup_success=false
  case $choice in
    1) setup_local_ollama && backend_setup_success=true ;;
    2) setup_lm_studio && backend_setup_success=true ;;
    3) setup_ollama_container && backend_setup_success=true ;;
    4) setup_llama_cpp && backend_setup_success=true ;;
    5) setup_localai && backend_setup_success=true ;;
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