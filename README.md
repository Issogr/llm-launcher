# 🚀 LLM Launcher

LLM Launcher is a Bash script that simplifies setting up and launching OpenWebUI with various Large Language Model (LLM) backends. With a single command, you can connect OpenWebUI to different LLM engines and start using them right away.

**Optimized Environment:**
- **Operating System**: Linux
- **Hardware**: Intel processors with integrated GPU (especially Intel Core Ultra)

## 📑 Table of Contents
- [🔌 Supported Backends](#-supported-backends)
- [✅ Prerequisites](#-prerequisites)
- [🚀 Quick Start](#-quick-start)
- [💻 Installation & Usage](#-installation--usage)
- [⚙️ Configuration Options](#️-configuration-options)
- [🖥️ Accessing the UI](#️-accessing-the-ui)
- [📡 Network Diagnostics](#-network-diagnostics)
- [🛠️ Hardware Detection](#-hardware-detection)
- [📝 License](#-license)
- [🙏 Acknowledgments](#-acknowledgments)

## 🔌 Supported Backends

The script supports the following LLM backends:

1. **Local Ollama**: Connects to an Ollama instance running on your local machine
2. **Remote LM Studio**: Connects to LM Studio running on another computer on your network
3. **Ollama in Docker container**: Runs Ollama in a container with Intel GPU support
4. **LocalAI with Intel acceleration**: Runs LocalAI in a container with Intel SYCL acceleration for optimal performance on Intel GPUs

## ✅ Prerequisites

Before using this script, you need to have the following installed:

- Docker (and Docker service running)
- Curl for connectivity testing
- One of the following text editors: nano, vim, vi (or set your $EDITOR environment variable)
- Docker permissions for the current user (or ability to run sudo commands)

Additionally, depending on your chosen backend:
- For option 1: Local Ollama installation
- For option 2: LM Studio running on a remote machine
- For option 3: No additional requirements (runs in Docker)
- For option 4: Intel GPU drivers installed (optimal for Intel Core Ultra processors)

## 🚀 Quick Start

```bash
# Download and make the script executable
curl -O https://raw.githubusercontent.com/Issogr/llm-launcher/main/llm-launcher.sh
chmod +x llm-launcher.sh

# Initial setup (recommended for first run)
./llm-launcher.sh --setup-dirs --create-config

# Launch normally with interactive backend selection
./llm-launcher.sh

# Or specify the backend directly
./llm-launcher.sh --non-interactive --backend=localai
```

## 💻 Installation & Usage

The script offers various options to adapt to your needs:

### Command Line Options

- `--help, -h`: Show help information
- `--setup-dirs`: Create the necessary directories
- `--create-config`: Create or reset the default configuration file
- `--edit-config`: Open the configuration file in your preferred text editor
- `--check-network`: Check Docker network status and container connectivity
- `--stop`: Stop containers and services started by this script
- `--non-interactive`: Run with default options (requires --backend)
- `--backend=TYPE`: Specify backend type: ollama, lmstudio, ollama-container, localai
- `--verbose`: Enable verbose output
- `--debug`: Enable debug output
- `--detect-hardware`: Detect hardware capabilities and suggest settings

The script will automatically:
- Check for required directories and create them if needed
- Create a default configuration file if none exists
- Guide you through selecting your preferred LLM backend
- Configure and launch OpenWebUI with the selected backend

## ⚙️ Configuration Options

The configuration file (`~/llm/llm-launcher.conf`) contains these customizable settings:

### Main Settings
- `DOCKER_NETWORK`: Name of the Docker network for container communication
- `OPEN_WEBUI_IMAGE`: Docker image for OpenWebUI
- `OPEN_WEBUI_NAME`: Name of the OpenWebUI container
- `OPEN_WEBUI_PORT`: Port for accessing OpenWebUI on your host (default: 3000)
- `MEMORY_LIMIT`: Memory limit for containers (e.g., "30G")
- `SHM_SIZE`: Shared memory size (e.g., "20g")

### Backend-specific Settings

**Local Ollama**: 
- No special configuration needed, uses your local Ollama installation

**Remote LM Studio**:
- `LM_STUDIO_HOST`: IP address of the remote machine running LM Studio
- `LM_STUDIO_PORT`: Port of the LM Studio API

**Ollama in Container**:
- `OLLAMA_CONTAINER_IMAGE`: Docker image for Ollama
- `OLLAMA_CONTAINER_NAME`: Name of the Ollama container
- `OLLAMA_CONTAINER_PORT`: Port for accessing Ollama's API on your host

**LocalAI**:
- `LOCALAI_IMAGE`: Docker image for LocalAI
- `LOCALAI_NAME`: Name of the LocalAI container
- `LOCALAI_PORT`: Port for accessing LocalAI's API on your host
- `LOCALAI_MODEL`: Default model to load (e.g., "gemma-3-4b-it-qat")
- `LOCALAI_EXTRA_FLAGS`: Additional flags to pass to LocalAI (e.g., "--threads 4")

## 🖥️ Accessing the UI

After running the script successfully, you can access OpenWebUI at:
```
http://localhost:[CONFIGURED_PORT]
```

The default port is 3000 unless you changed it in the configuration.

## 📡 Network Diagnostics

The script includes a network diagnostic feature to help you troubleshoot any connectivity issues between containers:

```bash
./llm-launcher.sh --check-network
```

This option will check:
- Status of the configured Docker network
- List of containers in the network
- Connectivity between containers

## 🛠️ Hardware Detection

The script can automatically detect your system's hardware capabilities and suggest optimal settings:

```bash
./llm-launcher.sh --detect-hardware
```

It detects:
- Total available memory
- Number of CPU cores
- GPU type (NVIDIA, AMD, Intel) and specific model for Intel GPUs
- Suggestions for memory, shared memory size, and thread count

## 📝 License

This script is provided as open-source under MIT License.

## 🙏 Acknowledgments

This script relies on the following projects:
- [OpenWebUI](https://github.com/open-webui/open-webui)
- [Ollama](https://github.com/ollama/ollama)
- [LM Studio](https://lmstudio.ai/)
- [LocalAI](https://github.com/go-skynet/LocalAI)