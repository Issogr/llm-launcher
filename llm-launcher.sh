#!/bin/bash
# ===========================================================
# Script to launch OpenWebUI with different LLM backends
# Supports: Local Ollama, Remote LM Studio, Ollama in container, local llama.cpp
# ===========================================================

# Main variable for configuration path
LLM_BASE_DIR="${HOME}/llm"
CONFIG_FILE="${LLM_BASE_DIR}/llm-launcher.conf"

# Colors to improve output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print error messages
error() {
  echo -e "${RED}ERROR: $1${NC}" >&2
  echo
}

# Function to print success messages
success() {
  echo -e "${GREEN}SUCCESS: $1${NC}"
  echo
}

# Function to print warnings
warning() {
  echo -e "${YELLOW}WARNING: $1${NC}"
  echo
}

# Function to print information
info() {
  echo -e "${BLUE}INFO: $1${NC}"
}

# Help function
show_help() {
  echo -e "${CYAN}========== LLM Launcher Help ==========${NC}"
  echo "This script launches OpenWebUI with different LLM backends."
  echo
  echo "Options:"
  echo "  --help, -h                Show this help message"
  echo "  --setup-dirs              Create the necessary standard directories"
  echo "  --create-config           Create or reset the default configuration file"
  echo "  --edit-config             Edit the configuration file"
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

# Function to verify and create necessary directories
setup_directories() {
  info "Checking and creating necessary directories..."
  
  # Create base directory
  mkdir -p "${LLM_BASE_DIR}"
  
  # Create directories for models
  mkdir -p "${LLM_BASE_DIR}/models/ollama"
  mkdir -p "${LLM_BASE_DIR}/models/llama_cpp"
  
  # Create directory for data
  mkdir -p "${LLM_BASE_DIR}/data/open-webui"
  
  # Create directory for logs (optional)
  mkdir -p "${LLM_BASE_DIR}/logs"
  
  success "Standard directories created successfully!"
  echo -e "Directory structure:"
  echo -e "${CYAN}${LLM_BASE_DIR}/${NC}"
  echo -e "${CYAN}├── models/${NC}"
  echo -e "${CYAN}│   ├── ollama/${NC}"
  echo -e "${CYAN}│   └── llama_cpp/${NC}"
  echo -e "${CYAN}├── data/${NC}"
  echo -e "${CYAN}│   └── open-webui/${NC}"
  echo -e "${CYAN}└── logs/${NC}"
  echo
}

# Function to create the default configuration file
create_default_config() {
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

# LM Studio remote
LM_STUDIO_HOST="192.168.1.154"
LM_STUDIO_PORT="1234"

# llama.cpp local
LLAMA_CPP_HOST="localhost"
LLAMA_CPP_PORT="8080"

# Memory requirements (in gigabytes)
MEMORY_LIMIT="30G"
SHM_SIZE="20g"
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
    exit 1
  fi
  
  success "Configuration modified."
}

# Function to check prerequisites
check_prerequisites() {
  info "Checking prerequisites..."
  
  # Check if docker is installed
  if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Install it before running this script."
    exit 1
  fi
  
  # Check if docker is running
  if ! docker info &> /dev/null; then
    error "Docker service is not running. Start it with 'sudo systemctl start docker'."
    exit 1
  fi
  
  # Check basic directories
  if [ ! -d "${LLM_BASE_DIR}" ]; then
    warning "Base directory ${LLM_BASE_DIR} not found. Do you want to create the standard directories? (y/n)"
    read -r choice
    if [[ $choice =~ ^[Yy]$ ]]; then
      setup_directories
    else
      error "Base directories not found. Run the command with --setup-dirs before continuing."
      exit 1
    fi
  fi
  
  # Check configuration file
  if [ ! -f "${CONFIG_FILE}" ]; then
    warning "Configuration file not found. Do you want to create it now? (y/n)"
    read -r choice
    if [[ $choice =~ ^[Yy]$ ]]; then
      create_default_config
      info "Do you want to edit the configuration file before continuing? (y/n)"
      read -r edit_choice
      if [[ $edit_choice =~ ^[Yy]$ ]]; then
        edit_config
      fi
    else
      error "Configuration file not found. Run the command with --create-config before continuing."
      exit 1
    fi
  fi
  
  # Load configurations
  source "${CONFIG_FILE}"
  
  success "Prerequisites verified"
}

# Function to update a Docker image to the latest version
update_docker_image() {
  local image_name="$1"
  local friendly_name="$2"
  
  info "Checking updates for $friendly_name ($image_name)..."
  
  # Check if the image already exists locally
  local image_exists_locally=false
  if docker image inspect "$image_name" &>/dev/null; then
    image_exists_locally=true
    local old_digest=$(docker image inspect --format='{{index .RepoDigests 0}}' "$image_name" 2>/dev/null || echo "")
    info "$friendly_name image found locally"
  else
    info "$friendly_name image not found locally"
  fi
  
  # Check if the image is available online (with timeout)
  local image_available_online=false
  info "Checking online availability of $friendly_name..."
  
  # First try to inspect the repository (faster than pull)
  if timeout 15s docker manifest inspect "$image_name" &>/dev/null; then
    image_available_online=true
    info "$friendly_name image available online"
  else
    warning "$friendly_name image not available online or connection problems"
  fi
  
  # Handle different cases
  if $image_available_online; then
    # The image is available online, proceed with download
    info "Downloading the latest version of $friendly_name..."
    
    if docker pull "$image_name"; then
      # Check if the image has been updated
      if $image_exists_locally; then
        local new_digest=$(docker image inspect --format='{{index .RepoDigests 0}}' "$image_name" 2>/dev/null || echo "")
        
        if [ -n "$old_digest" ] && [ "$old_digest" != "$new_digest" ]; then
          success "$friendly_name updated to the latest version"
        else
          info "$friendly_name is already at the latest version"
        fi
      else
        success "$friendly_name downloaded successfully"
      fi
      return 0
    else
      warning "Download failed for $friendly_name despite appearing to be available online"
      # Continue with the code below to use the local version
    fi
  fi
  
  # If we get here, the image is not available online or the download failed
  if $image_exists_locally; then
    # Ask the user if they want to use the local image
    echo -e -n "${YELLOW}The $friendly_name image is not available online. Do you want to use the local version? (y/n): ${NC}"
    read -r use_local
    
    if [[ $use_local =~ ^[Yy]$ ]]; then
      info "Using the local version of $friendly_name"
      return 0
    else
      error "Operation cancelled for $friendly_name"
      return 1
    fi
  else
    # It doesn't exist either online or locally
    error "The $friendly_name image is not available either online or locally"
    error "Operation cancelled"
    return 1
  fi
}

# Function to create the docker network
create_docker_network() {
  info "Checking Docker network '$DOCKER_NETWORK'..."
  
  if ! docker network inspect $DOCKER_NETWORK &>/dev/null; then
    info "Creating Docker network '$DOCKER_NETWORK'..."
    docker network create $DOCKER_NETWORK
    if [ $? -eq 0 ]; then
      success "Docker network '$DOCKER_NETWORK' created"
    else
      error "Unable to create Docker network '$DOCKER_NETWORK'"
      exit 1
    fi
  else
    info "Docker network '$DOCKER_NETWORK' already exists"
  fi
}

# Function to check and remove existing containers
remove_container_if_exists() {
  local container_name="$1"
  
  if [ "$(docker ps -aq -f name=^/${container_name}$)" ]; then
    info "Removing existing '$container_name' container..."
    docker rm -f $container_name
    if [ $? -eq 0 ]; then
      success "Container '$container_name' removed"
    else
      error "Unable to remove container '$container_name'"
      exit 1
    fi
  fi
}

# Function to configure and launch local Ollama (option 1)
setup_local_ollama() {
  info "Configuring Ollama on the local host..."
  
  # Configure environment variables for OpenWebUI
  OLLAMA_HOST_VAR="host.docker.internal"
  OLLAMA_URL_VAR="http://host.docker.internal:11434"
  EXTRA_PARAMS="--add-host=host.docker.internal:host-gateway"
  
  # Verify if Ollama is running on the host
  if ! curl -s http://localhost:11434/api/version > /dev/null; then
    warning "Cannot connect to Ollama on the local host."
    
    # Check if Ollama is installed
    if ! command -v ollama &> /dev/null; then
      error "Ollama does not appear to be installed on the system."
      warning "Install Ollama by following the instructions at https://ollama.ai/ before continuing."
      warning "Proceeding with launching OpenWebUI anyway..."
    else
      echo -e -n "${YELLOW}Do you want to try starting the Ollama service? (y/n): ${NC}"
      read -r restart_choice
      if [[ $restart_choice =~ ^[Yy]$ ]]; then
        info "Attempting to start the Ollama service..."
        
        # Try to identify the startup method on Linux
        if systemctl --version &>/dev/null; then
          # System with systemd
          if systemctl list-unit-files | grep -q ollama; then
            info "Starting Ollama via systemd..."
            sudo systemctl start ollama
          else
            info "Systemd service for Ollama not found, trying to start it manually..."
            nohup ollama serve > ${LLM_BASE_DIR}/logs/ollama.log 2>&1 &
          fi
        elif service --version &>/dev/null || which service &>/dev/null; then
          # System with service/init.d
          if [ -f /etc/init.d/ollama ]; then
            info "Starting Ollama via service..."
            sudo service ollama start
          else
            info "Init.d service for Ollama not found, trying to start it manually..."
            nohup ollama serve > ${LLM_BASE_DIR}/logs/ollama.log 2>&1 &
          fi
        else
          # Fallback - manual start
          info "Manual start of Ollama..."
          mkdir -p ${LLM_BASE_DIR}/logs
          nohup ollama serve > ${LLM_BASE_DIR}/logs/ollama.log 2>&1 &
        fi
        
        info "Waiting for Ollama to start (5 seconds)..."
        sleep 5
        
        # Verify connection again
        if ! curl -s http://localhost:11434/api/version > /dev/null; then
          error "Unable to start Ollama. Verify the installation."
          warning "If you just installed it, you might need to restart the system."
          warning "Proceeding with launching OpenWebUI anyway..."
        else
          success "Ollama started successfully!"
        fi
      else
        warning "Proceeding with launching OpenWebUI without active Ollama..."
      fi
    fi
  else
    success "Connection to Ollama on host verified"
  fi
  
  # Prepare parameters for OpenWebUI
  WEBUI_ENV_PARAMS=(
    "-e OLLAMA_BASE_URL=$OLLAMA_URL_VAR"
    "-e OLLAMA_API_HOST=$OLLAMA_HOST_VAR"
    "-e OLLAMA_API_PORT=${OLLAMA_URL_VAR##*:}"
  )
  
  # Save the backend type for final verification
  BACKEND_TYPE="ollama"
  BACKEND_URL="http://localhost:11434"
}

# Function to configure remote LM Studio (option 2)
setup_lm_studio() {
  info "Configuring to use LM Studio on another PC ($LM_STUDIO_HOST:$LM_STUDIO_PORT)..."
  
  # Configuration for LM Studio (OpenAI compatible API)
  OPENAI_API_KEY="lm-studio"  # Can be any value
  OPENAI_API_HOST=$LM_STUDIO_HOST
  OPENAI_API_PORT=$LM_STUDIO_PORT
  OPENAI_API_BASE_URL="http://$LM_STUDIO_HOST:$LM_STUDIO_PORT/v1"
  EXTRA_PARAMS=""
  
  # Check if LM Studio is reachable on the remote PC
  if ! curl -s "http://$LM_STUDIO_HOST:$LM_STUDIO_PORT/v1/models" > /dev/null; then
    warning "Cannot connect to LM Studio on $LM_STUDIO_HOST:$LM_STUDIO_PORT"
    warning "Make sure it is running and accessible from the network."
    
    echo -e -n "${YELLOW}Do you want to continue anyway? (y/n): ${NC}"
    read -r continue_choice
    if ! [[ $continue_choice =~ ^[Yy]$ ]]; then
      error "LM Studio configuration cancelled"
      return 1
    fi
    
    warning "Proceeding with launching OpenWebUI anyway..."
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
  
  # Update the image to the latest version
  if ! update_docker_image "$OLLAMA_CONTAINER_IMAGE" "Ollama Container"; then
    error "Unable to proceed with launching Ollama in container"
    return 1
  fi
  
  # Remove the Ollama container if it exists
  remove_container_if_exists $OLLAMA_CONTAINER_NAME
  
  # Start the Ollama container
  info "Starting container $OLLAMA_CONTAINER_NAME..."
  docker run -itd \
    -p 11434:11434 \
    --device=/dev/dri \
    -v "${LLM_BASE_DIR}/models/ollama:/root/.ollama/models" \
    -e no_proxy=localhost,127.0.0.1 \
    -e ZES_ENABLE_SYSMAN=1 \
    -e OLLAMA_INTEL_GPU=true \
    -e ONEAPI_DEVICE_SELECTOR=level_zero:0 \
    -e OLLAMA_HOST=0.0.0.0 \
    --memory="${MEMORY_LIMIT}" \
    --name=$OLLAMA_CONTAINER_NAME \
    -e bench_model="phi4" \
    -e DEVICE=iGPU \
    --shm-size="${SHM_SIZE}" \
    --network=$DOCKER_NETWORK \
    $OLLAMA_CONTAINER_IMAGE \
    bash -c 'ln -s /llm/ollama/ollama /usr/local/bin/ollama && cd /llm/scripts && source ipex-llm-init --gpu --device $DEVICE && bash start-ollama.sh && tail -f /dev/null'
  
  if [ $? -ne 0 ]; then
    error "Unable to start container $OLLAMA_CONTAINER_NAME"
    exit 1
  fi
  
  # Wait for Ollama to be fully started in the container
  info "Waiting for Ollama to fully start in the container (15 seconds)..."
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
  OPENAI_API_KEY="llama-cpp"  # Can be any value
  OPENAI_API_HOST="host.docker.internal"
  OPENAI_API_PORT=$LLAMA_CPP_PORT
  OPENAI_API_BASE_URL="http://host.docker.internal:$LLAMA_CPP_PORT/v1"
  EXTRA_PARAMS="--add-host=host.docker.internal:host-gateway"
  
  # Check if llama.cpp is reachable on the local host
  if ! curl -s "http://$LLAMA_CPP_HOST:$LLAMA_CPP_PORT/v1/models" > /dev/null; then
    warning "Cannot connect to llama.cpp on $LLAMA_CPP_HOST:$LLAMA_CPP_PORT"
    warning "Make sure llama.cpp is running with the server enabled"
    warning "Example command: ./llama.cpp/build/bin/server -m model.gguf -c 4096 --host 0.0.0.0 --port $LLAMA_CPP_PORT"
    
    echo -e -n "${YELLOW}Do you want to continue anyway? (y/n): ${NC}"
    read -r continue_choice
    if ! [[ $continue_choice =~ ^[Yy]$ ]]; then
      error "llama.cpp configuration cancelled"
      return 1
    fi
    
    warning "Proceeding with launching OpenWebUI anyway..."
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

# Function to start OpenWebUI
start_open_webui() {
  info "Preparing OpenWebUI..."
  
  # Update the image to the latest version
  if ! update_docker_image "$OPEN_WEBUI_IMAGE" "OpenWebUI"; then
    error "Unable to proceed with launching OpenWebUI"
    exit 1
  fi
  
  # Remove the container if it already exists
  remove_container_if_exists $OPEN_WEBUI_NAME
  
  # Start the OpenWebUI container
  info "Starting container $OPEN_WEBUI_NAME..."
  
  # Build the docker run command with the correct parameters
  docker_cmd="docker run -d \
    -p ${OPEN_WEBUI_PORT}:8080 \
    ${WEBUI_ENV_PARAMS[*]} \
    -v ${LLM_BASE_DIR}/data/open-webui:/app/backend/data \
    --name $OPEN_WEBUI_NAME \
    --network=$DOCKER_NETWORK"
  
  # Add any extra parameters
  if [ -n "$EXTRA_PARAMS" ]; then
    docker_cmd="$docker_cmd $EXTRA_PARAMS"
  fi
  
  # Add the image
  docker_cmd="$docker_cmd $OPEN_WEBUI_IMAGE"
  
  # Execute the command
  eval $docker_cmd
  
  if [ $? -ne 0 ]; then
    error "Unable to start container $OPEN_WEBUI_NAME"
    exit 1
  fi
  
  success "OpenWebUI started successfully"
}

# Function to verify connectivity between OpenWebUI and the backend
verify_connectivity() {
  info "Verifying connectivity between OpenWebUI and the backend..."
  
  sleep 5  # Wait for the container to be fully started
  
  # Verify connection to the backend based on the selected type
  if [[ "$BACKEND_TYPE" == "ollama" ]]; then
    # Verify connection to Ollama on the host
    docker exec $OPEN_WEBUI_NAME curl -s $OLLAMA_URL_VAR/api/version > /dev/null
    if [ $? -eq 0 ]; then
      success "OpenWebUI can reach Ollama on the host"
    else
      error "OpenWebUI cannot reach Ollama on the host"
      warning "Verify that Ollama is started and listening on all interfaces (0.0.0.0)"
    fi
  elif [[ "$BACKEND_TYPE" == "ollama-container" ]]; then
    # Verify connection to Ollama in the container
    docker exec $OPEN_WEBUI_NAME curl -s $BACKEND_URL > /dev/null
    if [ $? -eq 0 ]; then
      success "OpenWebUI can reach Ollama in the container"
    else
      error "OpenWebUI cannot reach Ollama in the container"
      warning "Verify that the Ollama container is started correctly and exposing the API on port 11434"
    fi
  elif [[ "$BACKEND_TYPE" == "lmstudio" ]]; then
    # Verify connection to LM Studio on the remote PC
    docker exec $OPEN_WEBUI_NAME curl -s $BACKEND_URL > /dev/null
    if [ $? -eq 0 ]; then
      success "OpenWebUI can reach LM Studio on the remote PC"
    else
      error "OpenWebUI cannot reach LM Studio on the remote PC"
      warning "Verify that LM Studio is started on the remote PC and is accessible from this host"
    fi
  elif [[ "$BACKEND_TYPE" == "llama-cpp" ]]; then
    # Verify connection to llama.cpp on the local host
    docker exec $OPEN_WEBUI_NAME curl -s $BACKEND_URL > /dev/null
    if [ $? -eq 0 ]; then
      success "OpenWebUI can reach llama.cpp on the local host"
    else
      error "OpenWebUI cannot reach llama.cpp on the local host"
      warning "Verify that llama.cpp is started and listening on all interfaces (0.0.0.0:$LLAMA_CPP_PORT)"
    fi
  fi
}

# Function to display access information
show_access_info() {
  echo
  echo "========================================================"
  echo -e "${GREEN}Configuration completed!${NC}"
  echo "========================================================"
  echo -e "OpenWebUI is accessible at: ${BLUE}http://localhost:${OPEN_WEBUI_PORT}${NC}"
  
  if [[ "$BACKEND_TYPE" == "ollama" ]]; then
    echo -e "Ollama API is accessible at: ${BLUE}http://localhost:11434${NC}"
  elif [[ "$BACKEND_TYPE" == "ollama-container" ]]; then
    echo -e "Ollama in container is accessible at: ${BLUE}http://localhost:11434${NC}"
    echo -e "Ollama Container: ${BLUE}$OLLAMA_CONTAINER_NAME${NC}"
  elif [[ "$BACKEND_TYPE" == "lmstudio" ]]; then
    echo -e "LM Studio API is accessible at: ${BLUE}http://$LM_STUDIO_HOST:$LM_STUDIO_PORT${NC}"
  elif [[ "$BACKEND_TYPE" == "llama-cpp" ]]; then
    echo -e "llama.cpp API is accessible at: ${BLUE}http://$LLAMA_CPP_HOST:$LLAMA_CPP_PORT${NC}"
  fi
  echo "========================================================"
}

# Main function
main() {
  echo "========================================================"
  echo "   🚀 OpenWebUI Configuration with LLM backend   "
  echo "========================================================"
  
  # Check CLI args
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
        edit_config
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
  
  # Check prerequisites
  check_prerequisites
  
  # Ask the user which backend to use
  echo
  echo "Choose which backend you want to use:"
  echo "1 - Ollama on your local host"
  echo "2 - LM Studio on another PC ($LM_STUDIO_HOST:$LM_STUDIO_PORT)"
  echo "3 - Ollama in Docker container (with Intel GPU)"
  echo "4 - Local llama.cpp on $LLAMA_CPP_HOST:$LLAMA_CPP_PORT (OpenAI compatible)"
  read -p "Enter your choice (1/2/3/4): " choice
  echo
  
  # Verify user input
  if [[ ! "$choice" =~ ^[1-4]$ ]]; then
    error "Invalid choice. Please enter a number from 1 to 4."
    exit 1
  fi
  
  # Create docker network
  create_docker_network
  
  # Configure backend based on user choice
  case $choice in
    1)
      if ! setup_local_ollama; then
        error "Local Ollama configuration failed"
        exit 1
      fi
      ;;
    2)
      if ! setup_lm_studio; then
        error "LM Studio configuration failed"
        exit 1
      fi
      ;;
    3)
      if ! setup_ollama_container; then
        error "Ollama in container configuration failed"
        exit 1
      fi
      ;;
    4)
      if ! setup_llama_cpp; then
        error "llama.cpp configuration failed"
        exit 1
      fi
      ;;
  esac
  
  # Start OpenWebUI
  start_open_webui
  
  # Verify connectivity
  verify_connectivity
  
  # Show access information
  show_access_info
}

# Program execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi